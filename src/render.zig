//! render.zig — Frame assembly and encoding pipeline.
//!
//! Translates C render.c + Odin render.odin to idiomatic Zig.
//!
//! Responsibilities:
//!   - Load binary manifests (per-frame instruction lists)
//!   - Atlas cache: tile-level LRU cache to avoid re-rendering source pages
//!   - Blit instructions onto canvas (solid fills + image tiles)
//!   - Producer-consumer encode pipeline (threaded)
//!   - Parallel frame assembly via OpenMP-style thread dispatch

const std = @import("std");
const Allocator = std.mem.Allocator;
const Img = @import("types.zig").Img;
const Inst = @import("types.zig").Inst;
const Registry = @import("types.zig").Registry;
const cli = @import("cli.zig");
const imgops = @import("imgops.zig");
const video = @import("video.zig");

// ── Constants ──────────────────────────────────────────────────────────────────

const MAX_INSTS: u32 = 65536;
const FRAME_QUEUE_SIZE: usize = 4;

// ── Error set ──────────────────────────────────────────────────────────────────

pub const RenderError = error{
    FileReadFailed,
    FileOpenFailed,
    InvalidManifest,
    TooManyInstructions,
    AllocationFailed,
    NoManifestsFound,
    EncoderOpenFailed,
    EncoderWriteFailed,
    InvalidCanvasDimensions,
    CanvasOverflow,
};

// ── Atlas cache (tile-level caching) ──────────────────────────────────────────
//
// Key: (op_id, tile_w, tile_h).
// Each entry stores a pre-scaled tile image ready to blit.
// Tiny entries (~50 KB) vs old full-page entries (~16 MB),
// so thousands fit in the budget.

const AtlasEntry = struct {
    op_id: i32 = -1,
    tile_w: u32 = 0,
    tile_h: u32 = 0,
    pixels: []u8 = &.{},
    channels: u32 = 0,
    stride: u32 = 0,
    bytes: u64 = 0,
    /// 0 = empty, 1 = occupied, 2 = tombstone
    valid: u8 = 0,
    lru: u32 = 0,
};

pub const AtlasCache = struct {
    entries: []AtlasEntry,
    capacity: usize,
    count: usize,
    total_bytes: u64,
    budget: u64,
    tick: u32,
    enabled: bool,
    hits: u64,
    misses: u64,
    allocator: Allocator,

    pub fn init(allocator: Allocator, budget: u64) AtlasCache {
        const cap: usize = 256;
        const entries = allocator.alloc(AtlasEntry, cap) catch return AtlasCache{
            .entries = &.{},
            .capacity = 0,
            .count = 0,
            .total_bytes = 0,
            .budget = budget,
            .tick = 0,
            .enabled = false,
            .hits = 0,
            .misses = 0,
            .allocator = allocator,
        };
        // Initialize all slots as empty.
        for (entries) |*e| e.* = AtlasEntry{};

        return AtlasCache{
            .entries = entries,
            .capacity = cap,
            .count = 0,
            .total_bytes = 0,
            .budget = budget,
            .tick = 0,
            .enabled = budget > 0,
            .hits = 0,
            .misses = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AtlasCache) void {
        for (self.entries) |*e| {
            if (e.valid == 1) {
                self.allocator.free(e.pixels);
            }
        }
        if (self.capacity > 0) self.allocator.free(self.entries);
        self.entries = &.{};
        self.capacity = 0;
        self.count = 0;
        self.total_bytes = 0;
    }

    fn hash(op_id: i32, tw: u32, th: u32) u32 {
        var h = @as(u32, @bitCast(op_id)) *% 2654435761;
        h ^= tw *% 374761393;
        h ^= th *% 668265263;
        if (h == 0) h = 1;
        return h;
    }

    /// Thread-safe read-only lookup.
    pub fn lookup(self: *AtlasCache, op_id: i32, tw: u32, th: u32) ?*AtlasEntry {
        if (!self.enabled) return null;
        const h = hash(op_id, tw, th);
        var probe: usize = 0;
        while (probe < self.capacity) : (probe += 1) {
            const idx = (h +% @as(u32, @intCast(probe))) & @as(u32, @intCast(self.capacity - 1));
            const e = &self.entries[idx];
            if (e.valid == 0) return null;
            if (e.valid == 2) continue;
            if (e.op_id == op_id and e.tile_w == tw and e.tile_h == th) {
                e.lru = self.tick;
                self.tick +|= 1;
                self.hits +|= 1;
                return e;
            }
        }
        self.misses +|= 1;
        return null;
    }

    /// Read-only lookup for parallel blit phase — does NOT update tick/hits/misses.
    /// Safe for concurrent use by multiple threads since it only reads immutable entry data.
    pub fn lookupReadOnly(self: *AtlasCache, op_id: i32, tw: u32, th: u32) ?*AtlasEntry {
        if (!self.enabled) {
            @branchHint(.unlikely);
            return null;
        }
        const h = hash(op_id, tw, th);
        var probe: usize = 0;
        while (probe < self.capacity) : (probe += 1) {
            const idx = (h +% @as(u32, @intCast(probe))) & @as(u32, @intCast(self.capacity - 1));
            const e = &self.entries[idx];
            if (e.valid == 0) return null;
            if (e.valid == 2) continue;
            if (e.op_id == op_id and e.tile_w == tw and e.tile_h == th) {
                return e;
            }
        }
        return null;
    }

    /// Resize the hash table when it reaches 75% capacity.
    /// Doubles capacity and rehashes all valid entries (tombstones are dropped).
    fn resize(self: *AtlasCache) void {
        const old_capacity = self.capacity;
        const new_capacity = old_capacity * 2;
        const new_entries = self.allocator.alloc(AtlasEntry, new_capacity) catch return;
        // Initialize all new slots as empty.
        for (new_entries) |*e| e.* = AtlasEntry{};

        // Rehash all valid entries into the new table.
        for (self.entries) |e| {
            if (e.valid != 1) continue;
            const h = hash(e.op_id, e.tile_w, e.tile_h);
            var probe: usize = 0;
            while (probe < new_capacity) : (probe += 1) {
                const idx = (h +% @as(u32, @intCast(probe))) & @as(u32, @intCast(new_capacity - 1));
                if (new_entries[idx].valid == 0) {
                    new_entries[idx] = e;
                    break;
                }
            }
        }

        self.allocator.free(self.entries);
        self.entries = new_entries;
        self.capacity = new_capacity;
    }

    fn evictLru(self: *AtlasCache) void {
        var oldest_idx: ?usize = null;
        var oldest_tick: u32 = std.math.maxInt(u32);
        for (self.entries, 0..) |e, i| {
            if (e.valid == 1 and e.lru < oldest_tick) {
                oldest_tick = e.lru;
                oldest_idx = i;
            }
        }
        if (oldest_idx) |idx| {
            self.total_bytes -= self.entries[idx].bytes;
            self.allocator.free(self.entries[idx].pixels);
            self.entries[idx].valid = 2;
            self.entries[idx].pixels = &.{};
            self.count -= 1;
        }
    }

    /// Copy tile pixel rows from src to dst.
    fn copyTilePixels(
        dst: []u8,
        src_pixels: []const u8,
        tw: u32,
        th: u32,
        src_channels: u32,
        src_stride: u32,
    ) void {
        @setRuntimeSafety(false);
        defer @setRuntimeSafety(true);
        const row_bytes = @as(usize, tw) * src_channels;
        for (0..@as(usize, th)) |y| {
            const src_off = @as(usize, y) * src_stride;
            const dst_off = @as(usize, y) * (tw * src_channels);
            const copy_len = @min(row_bytes, src_pixels.len -| src_off);
            const dst_len = dst.len -| dst_off;
            @memcpy(dst[dst_off..][0..@min(copy_len, dst_len)], src_pixels[src_off..][0..@min(copy_len, dst_len)]);
        }
    }

    /// Insert a tile into the atlas cache.
    /// Copies the pixel data from src.
    pub fn insert(
        self: *AtlasCache,
        op_id: i32,
        tw: u32,
        th: u32,
        src_pixels: []const u8,
        src_channels: u32,
        src_stride: u32,
    ) void {
        if (!self.enabled) return;

        const entry_bytes = @as(u64, tw) * @as(u64, th) * @as(u64, src_channels);

        // Resize if the table is 75% or more full.
        if (self.count >= self.capacity * 3 / 4) {
            self.resize();
        }

        // Evict until we have room.
        while (self.total_bytes + entry_bytes > self.budget and self.count > 0) {
            self.evictLru();
        }

        // Find an insertion slot.
        const h = hash(op_id, tw, th);
        var tombstone_idx: ?usize = null;
        var probe: usize = 0;
        while (probe < self.capacity) : (probe += 1) {
            const idx = (h +% @as(u32, @intCast(probe))) & @as(u32, @intCast(self.capacity - 1));
            const e = &self.entries[idx];
            if (e.valid == 0 or e.valid == 2) {
                const use_idx = tombstone_idx orelse idx;
                self.entries[use_idx].op_id = op_id;
                self.entries[use_idx].tile_w = tw;
                self.entries[use_idx].tile_h = th;
                self.entries[use_idx].channels = src_channels;
                self.entries[use_idx].stride = tw * src_channels;

                // Allocate and copy tile pixels.
                const new_pixels = self.allocator.alloc(u8, tw * th * src_channels) catch return;
                self.entries[use_idx].pixels = new_pixels;

                copyTilePixels(new_pixels, src_pixels, tw, th, src_channels, src_stride);

                self.entries[use_idx].bytes = entry_bytes;
                self.entries[use_idx].valid = 1;
                self.entries[use_idx].lru = self.tick;
                self.tick +|= 1;
                self.total_bytes +|= entry_bytes;
                self.count +|= 1;
                return;
            }
            if (e.valid == 2 and tombstone_idx == null) {
                tombstone_idx = idx;
            }
        }

        // All slots occupied — if we found a tombstone, reuse it.
        if (tombstone_idx) |use_idx| {
            self.entries[use_idx].op_id = op_id;
            self.entries[use_idx].tile_w = tw;
            self.entries[use_idx].tile_h = th;
            self.entries[use_idx].channels = src_channels;
            self.entries[use_idx].stride = tw * src_channels;

            const new_pixels = self.allocator.alloc(u8, tw * th * src_channels) catch return;
            self.entries[use_idx].pixels = new_pixels;

            copyTilePixels(new_pixels, src_pixels, tw, th, src_channels, src_stride);

            self.entries[use_idx].bytes = entry_bytes;
            self.entries[use_idx].valid = 1;
            self.entries[use_idx].lru = self.tick;
            self.tick +|= 1;
            self.total_bytes +|= entry_bytes;
            self.count +|= 1;
        }
    }
};

// ── Encode pipeline (producer-consumer queue) ──────────────────────────────────

const FrameSlot = struct {
    pixels: []u8 = &.{},
    filled: bool = false,
};

pub const EncodePipeline = struct {
    slots: [FRAME_QUEUE_SIZE]FrameSlot,
    write_idx: usize,
    read_idx: usize,
    count: usize,
    enc_width: u32,
    enc_height: u32,
    enc_channels: u32,
    mutex: std.Io.Mutex,
    can_write: std.Io.Condition,
    can_read: std.Io.Condition,
    done: bool,
    frames_written: u64,
    video_encoder: ?*VideoEncoderRef,
    allocator: Allocator,
    io: std.Io,

    /// Opaque reference to a video encoder — the caller provides write/deinit.
    pub const VideoEncoderRef = struct {
        write_fn: *const fn (ctx: *anyopaque, pixels: []const u8, w: u32, h: u32, channels: u32) void,
        ctx: *anyopaque,
    };

    pub fn init(
        allocator: Allocator,
        enc_ref: ?*VideoEncoderRef,
        width: u32,
        height: u32,
        channels: u32,
        io: std.Io,
    ) !EncodePipeline {
        var self = EncodePipeline{
            .slots = [_]FrameSlot{.{}} ** FRAME_QUEUE_SIZE,
            .write_idx = 0,
            .read_idx = 0,
            .count = 0,
            .enc_width = width,
            .enc_height = height,
            .enc_channels = channels,
            .mutex = std.Io.Mutex.init,
            .can_write = std.Io.Condition.init,
            .can_read = std.Io.Condition.init,
            .done = false,
            .frames_written = 0,
            .video_encoder = enc_ref,
            .allocator = allocator,
            .io = io,
        };

        // Validate canvas dimensions and check for overflow,
        // matching C reference render.c lines 818-820.
        if (width == 0 or height == 0) return error.InvalidCanvasDimensions;
        const max_usize = std.math.maxInt(usize);
        if (@as(usize, width) > max_usize / @as(usize, height) or
            @as(usize, width) * @as(usize, height) > max_usize / @as(usize, channels)) {
            return error.CanvasOverflow;
        }

        const canvas_bytes = @as(usize, width) * @as(usize, height) * @as(usize, channels);
        for (&self.slots) |*slot| {
            slot.pixels = try allocator.alloc(u8, canvas_bytes);
            slot.filled = false;
        }
        return self;
    }

    pub fn deinit(self: *EncodePipeline) void {
        for (&self.slots) |*slot| {
            if (slot.pixels.len > 0) {
                self.allocator.free(slot.pixels);
                slot.pixels = &.{};
            }
        }
    }

    pub fn push(self: *EncodePipeline, canvas: []const u8) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        // Wait until a slot is available.
        while (self.count >= FRAME_QUEUE_SIZE) {
            try self.can_write.wait(self.io, &self.mutex);
        }

        const slot = &self.slots[self.write_idx];
        @memcpy(slot.pixels[0..canvas.len], canvas);
        slot.filled = true;
        self.write_idx = (self.write_idx + 1) % FRAME_QUEUE_SIZE;
        self.count +|= 1;
        self.can_read.signal(self.io);
    }

    pub fn close(self: *EncodePipeline) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        self.done = true;
        self.can_read.broadcast(self.io);
    }

    /// Blocking: drain remaining frames and wait for the encoder thread to finish.
    /// The encoder thread proc is `encoderThreadFn`.
    pub fn encoderThreadFn(self: *EncodePipeline) void {
        while (true) {
            self.mutex.lock(self.io) catch return;

            while (self.count == 0 and !self.done) {
                self.can_read.wait(self.io, &self.mutex) catch return;
            }
            if (self.count == 0 and self.done) {
                self.mutex.unlock(self.io);
                break;
            }

            const slot = &self.slots[self.read_idx];
            self.read_idx = (self.read_idx + 1) % FRAME_QUEUE_SIZE;
            self.count -= 1;
            self.can_write.signal(self.io);
            self.mutex.unlock(self.io);

            // Encode outside the lock.
            if (self.video_encoder) |enc| {
                enc.write_fn(enc.ctx, slot.pixels, self.enc_width, self.enc_height, self.enc_channels);
            }

            self.mutex.lock(self.io) catch return;
            self.frames_written +|= 1;
            self.mutex.unlock(self.io);
        }
    }
};

// ── Manifest loading ──────────────────────────────────────────────────────────

/// Result of loading a single manifest file.
pub const LoadedManifest = struct {
    insts: []Inst,
    n: usize,

    pub fn deinit(self: *const LoadedManifest, allocator: Allocator) void {
        if (self.insts.len > 0) {
            allocator.free(self.insts);
        }
    }
};

/// Load a binary manifest file.
///
/// Binary format:
///   [0..4]   u32 src_w
///   [4..8]   u32 src_h
///   [8..12]  u32 n (number of instructions)
///   [12..]   n * 24 bytes: 6 × i32 per instruction (x, y, w, h, op_id, page_idx)
///
/// Coordinates are scaled and center-cropped to fill (target_w × target_h).
pub fn loadManifest(
    allocator: Allocator,
    data: []const u8,
    target_w: i32,
    target_h: i32,
) !LoadedManifest {
    if (data.len < 12) return error.InvalidManifest;

    const src_w = std.mem.readInt(u32, data[0..4], .little);
    const src_h = std.mem.readInt(u32, data[4..8], .little);
    const n = std.mem.readInt(u32, data[8..12], .little);

    if (n > MAX_INSTS) return error.TooManyInstructions;

    // Compute uniform scale with center-crop to fill output canvas.
    var scale: f64 = 1.0;
    var ox: f64 = 0.0;
    var oy: f64 = 0.0;
    if (src_w > 0 and src_h > 0 and (src_w != @as(u32, @bitCast(target_w)) or src_h != @as(u32, @bitCast(target_h)))) {
        const sx = @as(f64, @floatFromInt(target_w)) / @as(f64, @floatFromInt(src_w));
        const sy = @as(f64, @floatFromInt(target_h)) / @as(f64, @floatFromInt(src_h));
        scale = @max(sx, sy);
        ox = (@as(f64, @floatFromInt(target_w)) - @as(f64, @floatFromInt(src_w)) * scale) * 0.5;
        oy = (@as(f64, @floatFromInt(target_h)) - @as(f64, @floatFromInt(src_h)) * scale) * 0.5;
    }

    const insts = try allocator.alloc(Inst, n);
    errdefer allocator.free(insts);

    var off: usize = 12;
    for (0..n) |i| {
        if (off + 24 > data.len) return error.InvalidManifest;

        const bx = std.mem.readInt(i32, data[off..][0..4], .little);
        const by = std.mem.readInt(i32, data[off + 4 ..][0..4], .little);
        const bw = std.mem.readInt(i32, data[off + 8 ..][0..4], .little);
        const bh = std.mem.readInt(i32, data[off + 12 ..][0..4], .little);
        const op_id = std.mem.readInt(i32, data[off + 16 ..][0..4], .little);
        const page_idx = std.mem.readInt(i32, data[off + 20 ..][0..4], .little);
        off += 24;

        if (scale != 1.0) {
            const nx = @as(f64, @floatFromInt(bx)) * scale + ox;
            const ny = @as(f64, @floatFromInt(by)) * scale + oy;
            const nw = @as(f64, @floatFromInt(bw)) * scale;
            const nh = @as(f64, @floatFromInt(bh)) * scale;

            insts[i].x = @intFromFloat(nx + 0.5);
            insts[i].y = @intFromFloat(ny + 0.5);
            insts[i].w = @intFromFloat(nw + 0.5);
            insts[i].h = @intFromFloat(nh + 0.5);

            // Clamp to canvas bounds.
            if (insts[i].x < 0) insts[i].x = 0;
            if (insts[i].y < 0) insts[i].y = 0;
            if (insts[i].x + insts[i].w > target_w) insts[i].w = target_w - insts[i].x;
            if (insts[i].y + insts[i].h > target_h) insts[i].h = target_h - insts[i].y;
        } else {
            insts[i] = Inst{ .x = bx, .y = by, .w = bw, .h = bh, .op_id = op_id, .page_idx = page_idx };
            // Clamp to canvas bounds even at 1:1 scale.
            if (insts[i].x < 0) insts[i].x = 0;
            if (insts[i].y < 0) insts[i].y = 0;
            if (insts[i].w < 0) insts[i].w = 0;
            if (insts[i].h < 0) insts[i].h = 0;
            if (insts[i].x + insts[i].w > target_w) insts[i].w = target_w - insts[i].x;
            if (insts[i].y + insts[i].h > target_h) insts[i].h = target_h - insts[i].y;
        }
    }

    return LoadedManifest{ .insts = insts, .n = n };
}

/// Read a manifest file from disk and parse it.
pub fn loadManifestFile(
    allocator: Allocator,
    path: []const u8,
    target_w: i32,
    target_h: i32,
    io: std.Io,
) !LoadedManifest {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024 * 16));
    defer allocator.free(data);
    return loadManifest(allocator, data, target_w, target_h);
}

// ── Manifest directory scanning ────────────────────────────────────────────────

/// Scan a directory for .bin manifest files and return sorted paths.
pub fn scanManifests(allocator: Allocator, dir_path: []const u8, io: std.Io) ![][]const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var paths: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (name.len < 5) continue; // minimum: "a.bin"
        // Check .bin suffix (case-insensitive).
        const suffix = name[name.len - 4 ..];
        if (!std.ascii.eqlIgnoreCase(suffix, ".bin")) continue;
        // Skip fps.bin sidecar.
        if (std.mem.eql(u8, name, "fps.bin")) continue;

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, name });
        try paths.append(allocator, full_path);
    }

    // Sort by filename (frame order).
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    return try paths.toOwnedSlice(allocator);
}

// ── Solid fill ─────────────────────────────────────────────────────────────────

/// Fill a solid-color rectangle on the canvas.
/// op_id == -2 → white (255), op_id == -1 → black (0).
fn blitSolid(canvas: []u8, inst: *const Inst, width: u32, height: u32, channels: u32) void {
    @setRuntimeSafety(false);
    defer @setRuntimeSafety(true);
    if (inst.w <= 0 or inst.h <= 0) return;
    const val: u8 = if (inst.op_id == -2) 255 else 0;
    const sx0 = inst.x;
    const sy0 = inst.y;
    const width_i: i32 = @intCast(width);
    const height_i: i32 = @intCast(height);

    for (0..@as(usize, @intCast(inst.h))) |yy| {
        const dst_y = sy0 + @as(i32, @intCast(yy));
        if (dst_y < 0 or dst_y >= height_i) continue;

        var fill_x: i32 = sx0;
        var fill_w: i32 = inst.w;
        if (fill_x < 0) {
            fill_w += fill_x;
            fill_x = 0;
        }
        if (fill_x + fill_w > width_i) {
            fill_w = width_i - fill_x;
        }
        if (fill_w <= 0) continue;

        const row_start = @as(usize, @intCast(dst_y)) * @as(usize, width) * @as(usize, channels);
        const fill_start = row_start + @as(usize, @intCast(fill_x)) * @as(usize, channels);
        const fill_bytes = @as(usize, @intCast(fill_w)) * @as(usize, channels);

        if (channels == 3) {
            const end = @min(fill_start + @as(usize, @intCast(fill_w)) * 3, canvas.len);
            if (fill_start < canvas.len) {
                @memset(canvas[fill_start..end], val);
            }
        } else {
            // Grayscale fill.
            const end = @min(fill_start + fill_bytes, canvas.len);
            if (fill_start < canvas.len) {
                @memset(canvas[fill_start..end], val);
            }
        }
    }
}

// ── Tile blit ──────────────────────────────────────────────────────────────────

/// Blit a tile image onto the canvas at the position specified by inst.
/// Handles clipping to canvas bounds.
fn blitTile(
    canvas: []u8,
    tile_pixels: []const u8,
    tile_stride: u32,
    tile_channels: u32,
    inst: *const Inst,
    canvas_w: u32,
    canvas_h: u32,
    canvas_channels: u32,
) void {
    @setRuntimeSafety(false);
    defer @setRuntimeSafety(true);
    if (inst.w <= 0 or inst.h <= 0) {
        @branchHint(.unlikely);
        return;
    }
    const sx0 = inst.x;
    const sy0 = inst.y;
    const dw = inst.w;
    const dh = inst.h;
    const canvas_w_i: i32 = @intCast(canvas_w);
    const canvas_h_i: i32 = @intCast(canvas_h);

    for (0..@as(usize, @intCast(dh))) |yy| {
        const dst_y = sy0 + @as(i32, @intCast(yy));
        if (dst_y < 0 or dst_y >= canvas_h_i) continue;

        var copy_x: i32 = sx0;
        var copy_src_x: i32 = 0;
        var copy_w: i32 = dw;
        if (copy_x < 0) {
            copy_src_x = -copy_x;
            copy_w += copy_x;
            copy_x = 0;
        }
        if (copy_x + copy_w > canvas_w_i) {
            copy_w = canvas_w_i - copy_x;
        }
        if (copy_w <= 0) continue;

        const copy_bytes = @as(usize, @intCast(copy_w)) * @as(usize, tile_channels);
        const canvas_off = (@as(usize, @intCast(dst_y)) * @as(usize, canvas_w) + @as(usize, @intCast(copy_x))) * @as(usize, canvas_channels);
        const tile_off = @as(usize, @intCast(yy)) * @as(usize, tile_stride) + @as(usize, @intCast(copy_src_x)) * @as(usize, tile_channels);

        if (canvas_off + copy_bytes <= canvas.len and tile_off + copy_bytes <= tile_pixels.len) {
            @memcpy(canvas[canvas_off..][0..copy_bytes], tile_pixels[tile_off..][0..copy_bytes]);
        }
    }
}

// ── Frame assembly ─────────────────────────────────────────────────────────────

/// Context for rendering source images. The caller provides a function
/// that can render a PDF/image page to an Img.
pub const SourceRenderer = struct {
    render_fn: *const fn (ctx: *anyopaque, op_id: i32, w: u32, h: u32, channels: u32) ?Img,
    ctx: *anyopaque,
};

/// Concrete source renderer that loads images from the library.
/// Uses FFmpeg to decode image files and scales to tile dimensions.
pub const ImageSourceRenderer = struct {
    registry: *const Registry,
    allocator: Allocator,

    pub fn init(registry: *const Registry, allocator: Allocator) ImageSourceRenderer {
        return .{
            .registry = registry,
            .allocator = allocator,
        };
    }

    /// Render a source page to an Img at the specified dimensions.
    /// Returns null if the page cannot be loaded.
    pub fn renderPage(self: *ImageSourceRenderer, op_id: i32, w: u32, h: u32, channels: u32) ?Img {
        // Look up the registry entry.
        if (op_id < 0 or @as(usize, @intCast(op_id)) >= self.registry.entries.len) {
            return null;
        }

        const entry = self.registry.entries[@as(usize, @intCast(op_id))];
        const pdf_path = entry.pdf_path;

        // Create null-terminated path for FFmpeg.
        const path_z = self.allocator.dupeZ(u8, pdf_path) catch return null;
        defer self.allocator.free(path_z);

        // Load the image via FFmpeg.
        var img = video.imageLoad(self.allocator, path_z) catch return null;
        defer img.deinit();

        // If we need grayscale and the image is BGR, convert.
        if (channels == 1 and img.channels == 3) {
            var gray = imgops.toGray(&img) catch return null;
            defer gray.deinit();

            // Scale to target dimensions.
            const scaled = imgops.resizeArea(&gray, w, h) catch return null;
            return scaled;
        }

        // Scale to target dimensions (keep BGR if channels == 3).
        const scaled = imgops.resizeArea(&img, w, h) catch return null;
        return scaled;
    }

    /// Callback function compatible with SourceRenderer.render_fn.
    pub fn renderCallback(ctx: *anyopaque, op_id: i32, w: u32, h: u32, channels: u32) ?Img {
        const self: *ImageSourceRenderer = @ptrCast(@alignCast(ctx));
        return self.renderPage(op_id, w, h, channels);
    }

    /// Create a SourceRenderer from this instance.
    pub fn toSourceRenderer(self: *ImageSourceRenderer) SourceRenderer {
        return .{
            .render_fn = renderCallback,
            .ctx = @ptrCast(self),
        };
    }
};

/// Assemble a single frame onto the canvas from a list of instructions.
///
/// Phase 1 (sequential): Pre-populate the atlas cache with all needed tiles.
/// Phase 2 (parallel): Blit all instructions onto the canvas using multiple threads.
///
/// Each instruction writes to disjoint canvas Y-ranges, so no locking is needed
/// during the parallel blit phase (matching the C reference's OpenMP pattern).
pub fn assembleFrame(
    allocator: Allocator,
    canvas: []u8,
    insts: []const Inst,
    atlas: *AtlasCache,
    renderer: ?*SourceRenderer,
    width: u32,
    height: u32,
    channels: u32,
    thread_count: u32,
) void {
    const canvas_bytes = @as(usize, width) * @as(usize, height) * @as(usize, channels);
    @memset(canvas[0..canvas_bytes], 0);

    const n_instructions = insts.len;

    // ── Phase 1: Pre-populate atlas (sequential) ──────────────────
    //
    // Render and cache all source tiles needed by this frame.
    // This must be done sequentially to avoid concurrent atlas mutations.
    for (insts) |*inst| {
        if (inst.op_id < 0) continue; // solid fills need no atlas entry

        const dw: u32 = @intCast(inst.w);
        const dh: u32 = @intCast(inst.h);
        if (dw == 0 or dh == 0) continue;

        // Check if already cached.
        if (atlas.lookupReadOnly(inst.op_id, dw, dh)) |_| continue;

        // Cache miss — render source page and cache it.
        if (renderer) |r| {
            if (r.render_fn(r.ctx, inst.op_id, dw, dh, channels)) |img| {
                atlas.insert(inst.op_id, dw, dh, img.pixels, img.channels, img.stride);
                var owned = img;
                owned.deinit();
            }
        }
    }

    // ── Phase 2: Parallel blit (dynamic scheduling) ────────────────
    //
    // Dispatch instruction blitting across threads. Matching C reference:
    // `#pragma omp parallel for schedule(dynamic) if(n > 4)`
    const use_parallel = thread_count > 0 and n_instructions > 4;

    if (use_parallel) {
        var next_idx: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

        const thread_handles = allocator.alloc(std.Thread, thread_count) catch return;
        defer allocator.free(thread_handles);

        var spawned: usize = 0;
        for (0..thread_count) |t| {
            const ctx = BlitWorkerContext{
                .canvas = canvas,
                .insts = insts,
                .atlas = atlas,
                .width = width,
                .height = height,
                .channels = channels,
                .next_idx = &next_idx,
            };
            thread_handles[t] = std.Thread.spawn(.{}, blitWorker, .{ctx}) catch break;
            spawned += 1;
        }
        for (0..spawned) |i| thread_handles[i].join();
    } else {
        // Sequential fallback — matches C reference single-threaded path.
        for (insts) |*inst| {
            if (inst.op_id < 0) {
                blitSolid(canvas, inst, width, height, channels);
                continue;
            }

            const dw: u32 = @intCast(inst.w);
            const dh: u32 = @intCast(inst.h);
            if (dw == 0 or dh == 0) continue;

            const cached = atlas.lookupReadOnly(inst.op_id, dw, dh);
            if (cached) |entry| {
                blitTile(canvas, entry.pixels, entry.stride, entry.channels, inst, width, height, channels);
            }
        }
    }
}

// ── Parallel blit worker ────────────────────────────────────────────────

const BlitWorkerContext = struct {
    canvas: []u8,
    insts: []const Inst,
    atlas: *AtlasCache,
    width: u32,
    height: u32,
    channels: u32,
    next_idx: *std.atomic.Value(usize),
};

/// Worker function for parallel blit phase.
/// Uses atomic fetch-add to dynamically grab the next instruction index (schedule(dynamic)).
fn blitWorker(ctx: BlitWorkerContext) void {
    while (true) {
        const i = ctx.next_idx.fetchAdd(1, .monotonic);
        if (i >= ctx.insts.len) break;

        const inst = &ctx.insts[i];

        // Solid fill instructions.
        if (inst.op_id < 0) {
            blitSolid(ctx.canvas, inst, ctx.width, ctx.height, ctx.channels);
            continue;
        }

        const dw: u32 = @intCast(inst.w);
        const dh: u32 = @intCast(inst.h);
        if (dw == 0 or dh == 0) continue;

        const cached = ctx.atlas.lookupReadOnly(inst.op_id, dw, dh);
        if (cached) |entry| {
            blitTile(ctx.canvas, entry.pixels, entry.stride, entry.channels, inst, ctx.width, ctx.height, ctx.channels);
        }
    }
}

/// Frame assembly result — the caller gets a canvas back with frame data.
pub const FrameAssembly = struct {
    canvas: []u8,
    insts: []const Inst,
};

// ── FPS detection ──────────────────────────────────────────────────────────────

/// Read fps from a sidecar fps.bin file. Returns 0.0 if not found or invalid.
pub fn readFpsFile(allocator: Allocator, dir_path: []const u8, io: std.Io) f64 {
    const path = std.fmt.allocPrint(allocator, "{s}/fps.bin", .{dir_path}) catch return 0.0;
    defer allocator.free(path);

    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024)) catch return 0.0;
    defer allocator.free(data);

    if (data.len < @sizeOf(f64)) return 0.0;
    return @bitCast(std.mem.readInt(u64, data[0..@sizeOf(f64)], .little));
}

// ── Main render entry point ───────────────────────────────────────────────────

/// Options for the render stage.
pub const RenderOptions = struct {
    manifest_dir: []const u8 = "manifests_greedy",
    registry_path: []const u8 = "registry.bin",
    output: []const u8 = "output.mov",
    width: i32 = 0,
    height: i32 = 0,
    fps: f64 = 0.0,
    max_frames: u32 = 0,
    channels: u32 = 1,
    thread_count: u32 = 0,
};

/// Summary returned after rendering completes.
pub const RenderSummary = struct {
    total_frames: u32,
    width: u32,
    height: u32,
    fps: f64,
    elapsed_secs: f64,
    frames_per_sec: f64,
    cache_hit_pct: f64,
    channels: u32,
};

/// Main render function.
///
/// This is the high-level entry point that:
///   1. Loads the registry and manifests
///   2. Sets up the atlas cache
///   3. Opens the video encoder
///   4. Assembles and encodes frames in a threaded pipeline
///   5. Returns a summary
///
/// The caller must provide a `SourceRenderer` that can render source pages
/// (PDF, images) to Img objects. This abstracts away the PDF dependency.
pub fn render(
    allocator: Allocator,
    opts: RenderOptions,
    source_renderer: ?*SourceRenderer,
    encoder: ?*EncodePipeline.VideoEncoderRef,
    io: std.Io,
) !RenderSummary {
    // ── Scan manifests ──────────────────────────────────────────────
    const manifest_paths = scanManifests(allocator, opts.manifest_dir, io) catch {
        cli.err("cannot open manifests dir: {s}", .{opts.manifest_dir});
        return error.FileOpenFailed;
    };
    defer {
        for (manifest_paths) |p| allocator.free(p);
        allocator.free(manifest_paths);
    }

    if (manifest_paths.len == 0) {
        cli.err("no manifests found in: {s}", .{opts.manifest_dir});
        return error.NoManifestsFound;
    }

    cli.info("manifests: {d} frames", .{manifest_paths.len});

    // ── Auto-detect source dimensions from first manifest header ─────
    // Manifest binary format: first 8 bytes are src_w (u32 LE) + src_h (u32 LE).
    var src_w: u32 = 0;
    var src_h: u32 = 0;
    {
        const header_data = std.Io.Dir.cwd().readFileAlloc(io, manifest_paths[0], allocator, .limited(8)) catch null;
        if (header_data) |data| {
            defer allocator.free(data);
            if (data.len >= 8) {
                src_w = std.mem.readInt(u32, data[0..4], .little);
                src_h = std.mem.readInt(u32, data[4..8], .little);
            }
        }
    }

    // Compute output dimensions preserving source aspect ratio.
    // If neither width nor height is specified, use source dimensions directly.
    // If only one is specified, compute the other from the source aspect ratio.
    // Falls back to 7680×4320 if source dimensions are unavailable.
    var width: u32 = 0;
    var height: u32 = 0;
    if (opts.width > 0 and opts.height > 0) {
        width = @intCast(opts.width);
        height = @intCast(opts.height);
    } else if (opts.width > 0 and opts.height <= 0) {
        if (src_w > 0 and src_h > 0) {
            height = @intFromFloat(@as(f64, @floatFromInt(opts.width)) * @as(f64, @floatFromInt(src_h)) / @as(f64, @floatFromInt(src_w)) + 0.5);
        } else height = 4320;
    } else if (opts.width <= 0 and opts.height > 0) {
        if (src_w > 0 and src_h > 0) {
            width = @intFromFloat(@as(f64, @floatFromInt(opts.height)) * @as(f64, @floatFromInt(src_w)) / @as(f64, @floatFromInt(src_h)) + 0.5);
        } else width = 7680;
    } else {
        if (src_w > 0 and src_h > 0) {
            width = src_w;
            height = src_h;
        } else {
            width = 7680;
            height = 4320;
        }
    }

    const channels = if (opts.channels == 1 or opts.channels == 3) opts.channels else @as(u32, 1);

    // ── Auto-detect fps from sidecar ────────────────────────────────
    var fps = opts.fps;
    const src_fps = readFpsFile(allocator, opts.manifest_dir, io);
    if (fps <= 0.0 and src_fps > 0.0) {
        fps = src_fps;
        cli.info("auto-detected fps: {d:.2} (from source video)", .{fps});
    }
    if (fps <= 0.0) fps = 30.0;

    cli.info("render: {d}x{d} @ {d:.1} fps ({s})", .{
        width,
        height,
        fps,
        if (channels == 3) "color" else "grayscale",
    });

    // ── Pre-load all manifests ──────────────────────────────────────
    const loaded = try allocator.alloc(LoadedManifest, manifest_paths.len);
    defer {
        for (loaded) |*lm| lm.deinit(allocator);
        allocator.free(loaded);
    }

    var loaded_count: u32 = 0;
    for (manifest_paths, 0..) |path, i| {
        loaded[i] = loadManifestFile(allocator, path, @intCast(width), @intCast(height), io) catch blk: {
            cli.warn("skip bad manifest: {s}", .{path});
            break :blk LoadedManifest{ .insts = &.{}, .n = 0 };
        };
        if (loaded[i].n > 0) loaded_count +|= 1;
    }

    cli.info("loaded: {d} manifests ({d} frames with data)", .{ loaded_count, manifest_paths.len });

    // ── Atlas cache ─────────────────────────────────────────────────
    var atlas = AtlasCache.init(allocator, 256 * 1024 * 1024); // 256 MB budget
    defer atlas.deinit();

    // ── Canvas buffer ───────────────────────────────────────
    if (width == 0 or height == 0) return error.InvalidCanvasDimensions;
    const max_usize = std.math.maxInt(usize);
    if (@as(usize, width) > max_usize / @as(usize, height) or
        @as(usize, width) * @as(usize, height) > max_usize / @as(usize, channels)) {
        return error.CanvasOverflow;
    }
    const canvas_bytes = @as(usize, width) * @as(usize, height) * @as(usize, channels);
    const canvas = try allocator.alloc(u8, canvas_bytes);
    defer allocator.free(canvas);

    // ── Determine max frames to process ─────────────────────────────
    var max_frames_actual: u32 = @intCast(manifest_paths.len);
    if (opts.max_frames > 0 and opts.max_frames < max_frames_actual) {
        max_frames_actual = opts.max_frames;
    }

    // ── Encode pipeline ─────────────────────────────────────────────
    var pipeline = try EncodePipeline.init(allocator, encoder, width, height, channels, io);
    defer pipeline.deinit();

    // Start encoder thread.
    const enc_thread = try std.Thread.spawn(.{}, EncodePipeline.encoderThreadFn, .{&pipeline});

    // ── Process frames ──────────────────────────────────────────────
    var frames_done: u32 = 0;
    const start_time = std.Io.Clock.now(.awake, io).nanoseconds;

    for (0..max_frames_actual) |fi| {
        const insts = loaded[fi].insts;

        // Assemble frame (parallel blit when thread_count > 0 and n > 4).
        assembleFrame(allocator, canvas, insts, &atlas, source_renderer, width, height, channels, opts.thread_count);

        // Push to encode pipeline.
        try pipeline.push(canvas);
        frames_done +|= 1;

        // Progress reporting.
        if (!cli.ctx().quiet and frames_done % 30 == 0) {
            const now = std.Io.Clock.now(.awake, io).nanoseconds;
            const elapsed = @as(f64, @floatFromInt(now - start_time)) / 1_000_000_000.0;
            const fps_out = @as(f64, @floatFromInt(frames_done)) / @max(elapsed, 0.001);
            const cache_pct = if (atlas.hits + atlas.misses > 0)
                @as(f64, @floatFromInt(atlas.hits)) / @as(f64, @floatFromInt(atlas.hits + atlas.misses)) * 100.0
            else
                0.0;
            cli.progressFrame("render", frames_done, @intCast(manifest_paths.len), fps_out, cache_pct);
        }
    }

    // ── Flush and join ──────────────────────────────────────────────
    pipeline.close() catch {};
    enc_thread.join();

    // ── Cleanup ─────────────────────────────────────────────────────
    const end_time = std.Io.Clock.now(.awake, io).nanoseconds;
    const total_secs = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000_000.0;
    const out_fps = @as(f64, @floatFromInt(frames_done)) / @max(total_secs, 0.001);
    const cache_lookups = atlas.hits + atlas.misses;
    const cache_hit_pct = if (cache_lookups > 0)
        100.0 * @as(f64, @floatFromInt(atlas.hits)) / @as(f64, @floatFromInt(cache_lookups))
    else
        0.0;

    var summary_buf: [256]u8 = undefined;
    const summary_str = std.fmt.bufPrint(&summary_buf, "render complete in {d:.2}s | {d:.2} fps | {d} frames | cache {d:.1}%", .{
        total_secs,
        out_fps,
        frames_done,
        cache_hit_pct,
    }) catch "render complete";
    cli.progressDone(summary_str);

    return RenderSummary{
        .total_frames = frames_done,
        .width = width,
        .height = height,
        .fps = fps,
        .elapsed_secs = total_secs,
        .frames_per_sec = out_fps,
        .cache_hit_pct = cache_hit_pct,
        .channels = channels,
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────────

test "atlas cache: init, insert, lookup, evict" {
    const allocator = std.testing.allocator;
    var atlas = AtlasCache.init(allocator, 1024); // tiny budget for testing
    defer atlas.deinit();

    try std.testing.expect(atlas.enabled);
    try std.testing.expectEqual(@as(usize, 0), atlas.count);

    // Insert a tile (8x8 grayscale = 64 bytes).
    const tile = try allocator.alloc(u8, 64);
    defer allocator.free(tile);
    @memset(tile, 42);

    atlas.insert(0, 8, 8, tile, 1, 8);
    try std.testing.expectEqual(@as(usize, 1), atlas.count);
    try std.testing.expectEqual(@as(u64, 64), atlas.total_bytes);

    // Lookup should hit.
    const found = atlas.lookup(0, 8, 8);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(@as(u8, 42), found.?.pixels[0]);

    // Lookup with different dimensions should miss.
    const miss = atlas.lookup(0, 16, 16);
    try std.testing.expect(miss == null);
}

test "atlas cache: LRU eviction" {
    const allocator = std.testing.allocator;
    // Budget = 128 bytes, so second tile (64 bytes) fits but third should evict.
    var atlas = AtlasCache.init(allocator, 128);
    defer atlas.deinit();

    const tile = try allocator.alloc(u8, 64);
    defer allocator.free(tile);
    @memset(tile, 1);

    atlas.insert(0, 8, 8, tile, 1, 8);
    @memset(tile, 2);
    atlas.insert(1, 8, 8, tile, 1, 8);

    // Third insert should evict one.
    @memset(tile, 3);
    atlas.insert(2, 8, 8, tile, 1, 8);

    // The oldest (op_id=0) should have been evicted.
    try std.testing.expect(atlas.count <= 2);
}

test "blitSolid: fills canvas" {
    var canvas: [48]u8 = undefined;
    @memset(&canvas, 0);

    const inst = Inst{ .x = 0, .y = 0, .w = 4, .h = 2, .op_id = -2, .page_idx = 0 };
    blitSolid(&canvas, &inst, 4, 12, 1);

    // Should be all 255 (white) for the first 8 pixels.
    for (0..8) |i| {
        try std.testing.expectEqual(@as(u8, 255), canvas[i]);
    }
}

test "blitTile: copies tile to canvas" {
    const allocator = std.testing.allocator;
    const canvas = try allocator.alloc(u8, 16);
    defer allocator.free(canvas);
    @memset(canvas, 0);

    const tile = try allocator.alloc(u8, 4);
    defer allocator.free(tile);
    tile[0] = 10;
    tile[1] = 20;
    tile[2] = 30;
    tile[3] = 40;

    const inst = Inst{ .x = 2, .y = 0, .w = 2, .h = 2, .op_id = 0, .page_idx = 0 };
    blitTile(canvas, tile, 2, 1, &inst, 4, 4, 1);

    // Row 0: pixels at x=2,3 should be 10,20
    try std.testing.expectEqual(@as(u8, 10), canvas[2]);
    try std.testing.expectEqual(@as(u8, 20), canvas[3]);
    // Row 1: pixels at x=2,3 should be 30,40
    try std.testing.expectEqual(@as(u8, 30), canvas[6]);
    try std.testing.expectEqual(@as(u8, 40), canvas[7]);
}

test "loadManifest: parses binary data" {
    const allocator = std.testing.allocator;

    // Build a tiny manifest: 2x2 source, 1 instruction.
    var data: [36]u8 = undefined;
    // src_w=2, src_h=2, n=1
    std.mem.writeInt(u32, data[0..4], 2, .little);
    std.mem.writeInt(u32, data[4..8], 2, .little);
    std.mem.writeInt(u32, data[8..12], 1, .little);
    // inst: x=0, y=0, w=2, h=2, op_id=-1, page_idx=0
    std.mem.writeInt(i32, data[12..16], 0, .little);
    std.mem.writeInt(i32, data[16..20], 0, .little);
    std.mem.writeInt(i32, data[20..24], 2, .little);
    std.mem.writeInt(i32, data[24..28], 2, .little);
    std.mem.writeInt(i32, data[28..32], -1, .little);
    std.mem.writeInt(i32, data[32..36], 0, .little);

    const result = try loadManifest(allocator, &data, 2, 2);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.n);
    try std.testing.expectEqual(@as(i32, -1), result.insts[0].op_id);
    try std.testing.expectEqual(@as(i32, 0), result.insts[0].x);
    try std.testing.expectEqual(@as(i32, 0), result.insts[0].y);
}

test "loadManifest: scales to target" {
    const allocator = std.testing.allocator;

    // Source 100x100, target 200x200 → 2x upscale.
    var data: [36]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], 100, .little);
    std.mem.writeInt(u32, data[4..8], 100, .little);
    std.mem.writeInt(u32, data[8..12], 1, .little);
    std.mem.writeInt(i32, data[12..16], 10, .little); // x
    std.mem.writeInt(i32, data[16..20], 20, .little); // y
    std.mem.writeInt(i32, data[20..24], 50, .little); // w
    std.mem.writeInt(i32, data[24..28], 50, .little); // h
    std.mem.writeInt(i32, data[28..32], 5, .little); // op_id
    std.mem.writeInt(i32, data[32..36], 0, .little); // page_idx

    const result = try loadManifest(allocator, &data, 200, 200);
    defer result.deinit(allocator);

    // With 2x scale: x=10*2=20, y=20*2=40, w=50*2=100, h=50*2=100
    try std.testing.expectEqual(@as(i32, 20), result.insts[0].x);
    try std.testing.expectEqual(@as(i32, 40), result.insts[0].y);
    try std.testing.expectEqual(@as(i32, 100), result.insts[0].w);
    try std.testing.expectEqual(@as(i32, 100), result.insts[0].h);
}

test "assembleFrame: renders solid fills" {
    const allocator = std.testing.allocator;
    const width: u32 = 4;
    const height: u32 = 4;
    const channels: u32 = 1;
    const canvas_bytes = @as(usize, width) * height * channels;
    const canvas = try allocator.alloc(u8, canvas_bytes);
    defer allocator.free(canvas);

    var atlas = AtlasCache.init(allocator, 0);
    defer atlas.deinit();

    const insts = [_]Inst{
        Inst{ .x = 0, .y = 0, .w = 2, .h = 2, .op_id = -2, .page_idx = 0 }, // white
        Inst{ .x = 2, .y = 2, .w = 2, .h = 2, .op_id = -1, .page_idx = 0 }, // black
    };

    assembleFrame(allocator, canvas, &insts, &atlas, null, width, height, channels, 0);

    // Top-left 2x2 should be white (255).
    try std.testing.expectEqual(@as(u8, 255), canvas[0]);
    try std.testing.expectEqual(@as(u8, 255), canvas[1]);
    try std.testing.expectEqual(@as(u8, 255), canvas[4]);
    try std.testing.expectEqual(@as(u8, 255), canvas[5]);

    // Bottom-right 2x2 should be black (0).
    try std.testing.expectEqual(@as(u8, 0), canvas[10]);
    try std.testing.expectEqual(@as(u8, 0), canvas[11]);
    try std.testing.expectEqual(@as(u8, 0), canvas[14]);
    try std.testing.expectEqual(@as(u8, 0), canvas[15]);
}
