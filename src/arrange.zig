/// arrange.zig — Greedy block solver + feature extraction + matching pipeline.
///
/// This is a Zig translation of BadApplestein's arrange.c. It:
///   1. Decodes video frames via the video module.
///   2. Runs a greedy block solver to partition each frame into tiles.
///   3. Extracts multi-resolution features for non-hero tiles.
///   4. Matches features against a pre-built library using coarse-to-fine search.
///   5. Writes per-frame binary manifests for the renderer.
///
/// Unlike the C version which uses global state, this module encapsulates all
/// mutable state in an `Arranger` struct with explicit allocator-based memory
/// management.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const Img = types.Img;
const FeatureDB = types.FeatureDB;
const Registry = types.Registry;
const Inst = types.Inst;
const imgops = @import("imgops.zig");
const match_mod = @import("match.zig");

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const CELL: u32 = 8;
const CACHE_PROBE_MAX: usize = 32;

// FNV-1a constants
const FNV_OFFSET: u64 = 14695981039346656037;
const FNV_PRIME: u64 = 1099511628211;

// ---------------------------------------------------------------------------
// Hash functions
// ---------------------------------------------------------------------------

/// FNV-1a 64-bit hash. Returns h | 1 (0 = empty sentinel).
fn fnv1a64(data: []const u8) u64 {
    var h: u64 = FNV_OFFSET;
    for (data) |byte| {
        h ^= byte;
        h *%= FNV_PRIME;
    }
    return h | 1;
}

/// Hash a full feature vector using a sparse 64-byte sample across all scales.
/// This is fast (~64 ns/tile) and collision probability is negligible.
fn fullFeatHash(feat: []const u8) u64 {
    var h: u64 = FNV_OFFSET;
    const n: usize = @min(feat.len, 64);
    var step: usize = feat.len / n;
    if (step < 1) step = 1;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        h ^= feat[i * step];
        h *%= FNV_PRIME;
    }
    return h | 1;
}

/// Hash a coarse feature (≤ 1 KB) — hash all bytes (~1 μs).
fn coarseFeatHash(feat: []const u8) u64 {
    return fnv1a64(feat);
}

// ---------------------------------------------------------------------------
// Cache: open-addressing hash map with linear probing
// ---------------------------------------------------------------------------

const CacheSlot = struct {
    hash: u64 = 0,
    pid: i32 = 0,
};

const Cache = struct {
    slots: []CacheSlot,
    count: usize,
    allocator: Allocator,

    fn init(allocator: Allocator) Cache {
        return .{
            .slots = &.{},
            .count = 0,
            .allocator = allocator,
        };
    }

    fn deinit(self: *Cache) void {
        self.allocator.free(self.slots);
        self.slots = &.{};
        self.count = 0;
    }

    /// Look up a hash in the cache. Returns the pid if found.
    fn lookup(self: *const Cache, hash: u64) ?i32 {
        if (self.slots.len == 0) return null;
        const mask = self.slots.len - 1;
        var idx = hash & mask;
        var probes: usize = 0;
        while (probes < CACHE_PROBE_MAX and probes < self.slots.len) : (probes += 1) {
            const slot = self.slots[idx];
            if (slot.hash == 0) return null; // empty → miss
            if (slot.hash == hash) return slot.pid;
            idx = (idx + 1) & mask;
        }
        return null;
    }

    /// Grow the cache to double its current capacity (or 2048 if empty).
    fn grow(self: *Cache) !void {
        const new_cap: usize = if (self.slots.len == 0) 2048 else self.slots.len * 2;
        const new_slots = try self.allocator.alloc(CacheSlot, new_cap);
        @memset(new_slots, CacheSlot{});

        if (self.slots.len > 0) {
            const mask = new_cap - 1;
            for (self.slots) |slot| {
                if (slot.hash != 0) {
                    var idx = slot.hash & mask;
                    while (new_slots[idx].hash != 0) idx = (idx + 1) & mask;
                    new_slots[idx] = slot;
                }
            }
            self.allocator.free(self.slots);
        }

        self.slots = new_slots;
    }

    /// Insert a hash→pid mapping. Grows if load factor exceeds 75%.
    fn put(self: *Cache, hash: u64, pid: i32) !void {
        if (self.count + 1 > self.slots.len * 3 / 4) {
            try self.grow();
        }
        const mask = self.slots.len - 1;
        var idx = hash & mask;
        while (self.slots[idx].hash != 0) idx = (idx + 1) & mask;
        self.slots[idx].hash = hash;
        self.slots[idx].pid = pid;
        self.count += 1;
    }

    /// Clear all entries without reallocating.
    fn clear(self: *Cache) void {
        if (self.slots.len > 0) {
            @memset(self.slots, CacheSlot{});
        }
        self.count = 0;
    }
};

// ---------------------------------------------------------------------------
// SolveBuffers: reusable buffers for the greedy solver
// ---------------------------------------------------------------------------

const TileSpec = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    manifest_idx: usize,
};

const SolveBuffers = struct {
    sum: ?[]i64 = null,
    visited: ?[]u8 = null,
    coarse_hit: ?[]i32 = null,
    miss_idx: ?[]usize = null,
    specs: ?std.ArrayList(TileSpec) = null,
    cap_w: u32 = 0,
    cap_h: u32 = 0,

    fn deinit(self: *SolveBuffers, allocator: Allocator) void {
        if (self.sum) |s| allocator.free(s);
        if (self.visited) |v| allocator.free(v);
        if (self.coarse_hit) |ch| allocator.free(ch);
        if (self.miss_idx) |mi| allocator.free(mi);
        if (self.specs) |*sp| sp.deinit(allocator);
    }
};

// ---------------------------------------------------------------------------
// Timings: phase breakdown for diagnostics
// ---------------------------------------------------------------------------

pub const Timings = struct {
    gray: f64 = 0,
    solve: f64 = 0,
    feat: f64 = 0,
    match_time: f64 = 0,
    write: f64 = 0,
    tiles: u64 = 0,
    hits: u64 = 0,

    pub fn reset(self: *Timings) void {
        self.* = .{};
    }
};

// ---------------------------------------------------------------------------
// Arranger: the main pipeline struct
// ---------------------------------------------------------------------------

pub const Arranger = struct {
    allocator: Allocator,

    /// Cached parameters from the feature DB.
    G: u32,
    feat_len: u32,
    n_scales: u32,
    scales: []const u32,
    has_edges: bool,
    channels: u32,

    /// Coarse feature length (first scale level gray only).
    coarse_len: u32,

    /// Hero block parameters.
    max_block: u32,
    hero_min: u32,

    /// Reusable solver buffers.
    bufs: SolveBuffers,

    /// Reusable miss index buffer for cache phase.
    miss_idx: std.ArrayList(usize),

    /// Feature + full caches.
    coarse_cache: Cache,
    full_cache: Cache,

    pub fn init(allocator: Allocator, db: *const FeatureDB, fw: u32, fh: u32, max_block_pct: f64, hero_min_pct: f64) Arranger {
        const coarse_len_val = db.scales[0] * db.scales[0];

        const mb_f = @as(f64, @floatFromInt(fw)) * max_block_pct;
        var max_block: u32 = @intFromFloat(mb_f);
        max_block = (max_block / 8) * 8;
        if (max_block < 8) max_block = 8;

        const hero_f = @as(f64, @floatFromInt(fh)) * hero_min_pct;
        const hero_min: u32 = @intFromFloat(hero_f);

        return Arranger{
            .allocator = allocator,
            .G = db.G,
            .feat_len = db.feat_len,
            .n_scales = db.n_scales,
            .scales = db.scales,
            .has_edges = db.has_edges,
            .channels = db.channels,
            .coarse_len = coarse_len_val,
            .max_block = max_block,
            .hero_min = hero_min,
            .bufs = SolveBuffers{},
            .miss_idx = .empty,
            .coarse_cache = Cache.init(allocator),
            .full_cache = Cache.init(allocator),
        };
    }

    pub fn deinit(self: *Arranger) void {
        self.bufs.deinit(self.allocator);
        self.miss_idx.deinit(self.allocator);
        self.coarse_cache.deinit();
        self.full_cache.deinit();
    }

    // -------------------------------------------------------------------
    // Phase 1: Greedy block solver
    // -------------------------------------------------------------------

    /// Run the greedy block solver on a grayscale image. Returns a list of
    /// tile specs (non-hero tiles that need feature extraction/matching).
    fn solveGreedy(
        self: *Arranger,
        gray: []const u8,
        w: u32,
        h: u32,
        manifest: *std.ArrayList(Inst),
    ) !std.ArrayList(TileSpec) {
        const gw = (w + CELL - 1) / CELL;
        const gh = (h + CELL - 1) / CELL;

        // Ensure sum buffer exists and is large enough.
        const sum_needed: usize = @as(usize, w + 1) * @as(usize, h + 1);
        if (self.bufs.sum == null or self.bufs.cap_w < w or self.bufs.cap_h < h) {
            if (self.bufs.sum) |s| self.allocator.free(s);
            self.bufs.sum = try self.allocator.alloc(i64, sum_needed);
            self.bufs.cap_w = w;
            self.bufs.cap_h = h;
        }
        const sum = self.bufs.sum.?;

        // Zero-init first row and first column for integral image.
        const stride = @as(usize, w + 1);
        @memset(sum[0 .. w + 1], 0);
        var y: u32 = 1;
        while (y <= h) : (y += 1) {
            sum[y * stride] = 0;
        }

        // Single-pass threshold + integral image.
        y = 0;
        while (y < h) : (y += 1) {
            var rowsum: i64 = 0;
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                const val: i64 = if (gray[y * w + x] > 127) 1 else 0;
                rowsum += val;
                sum[(y + 1) * stride + (x + 1)] = rowsum + sum[y * stride + (x + 1)];
            }
        }

        // Ensure visited buffer.
        const vis_needed: usize = @as(usize, gh) * gw;
        if (self.bufs.visited == null) {
            self.bufs.visited = try self.allocator.alloc(u8, vis_needed);
        }
        const visited = self.bufs.visited.?;
        @memset(visited[0..vis_needed], 0);

        // Ensure specs list.
        if (self.bufs.specs == null) {
            self.bufs.specs = .empty;
        }
        var specs = self.bufs.specs.?;
        specs.clearRetainingCapacity();

        var n: usize = 0;

        // Phase 1: Serial greedy solver — identify all tiles.
        var cy: u32 = 0;
        while (cy < gh) : (cy += 1) {
            var cx: u32 = 0;
            while (cx < gw) : (cx += 1) {
                const vy = cy * gw;
                if (visited[vy + cx] != 0) continue;

                const x = cx * CELL;
                const yy = cy * CELL;
                const color: i32 = if (gray[yy * w + x] > 127) 1 else 0;

                // Expand width.
                var mcw: u32 = 1;
                var mch: u32 = 1;
                while (cx + mcw + 1 <= gw and mcw + 1 <= self.max_block / CELL) {
                    var any_visited = false;
                    var ey: u32 = cy;
                    while (ey < cy + mch) : (ey += 1) {
                        if (visited[ey * gw + (cx + mcw)] != 0) {
                            any_visited = true;
                            break;
                        }
                    }
                    if (any_visited) break;

                    const x0 = cx * CELL;
                    const y0 = cy * CELL;
                    var x1: u32 = (cx + mcw + 1) * CELL;
                    var y1: u32 = (cy + mch) * CELL;
                    if (x1 > w) x1 = w;
                    if (y1 > h) y1 = h;
                    const cnt = sum[y1 * stride + x1] - sum[y0 * stride + x1] -
                        sum[y1 * stride + x0] + sum[y0 * stride + x0];
                    const area: i64 = @intCast((x1 - x0) * (y1 - y0));
                    const pure = if (color == 1) (cnt == area) else (cnt == 0);
                    if (pure) mcw += 1 else break;
                }
                while (cy + mch + 1 <= gh and mch + 1 <= self.max_block / CELL) {
                    var any_visited = false;
                    var ex: u32 = cx;
                    while (ex < cx + mcw) : (ex += 1) {
                        if (visited[(cy + mch) * gw + ex] != 0) {
                            any_visited = true;
                            break;
                        }
                    }
                    if (any_visited) break;

                    const x0 = cx * CELL;
                    const y0 = cy * CELL;
                    var x1: u32 = (cx + mcw) * CELL;
                    var y1: u32 = (cy + mch + 1) * CELL;
                    if (x1 > w) x1 = w;
                    if (y1 > h) y1 = h;
                    const cnt = sum[y1 * stride + x1] - sum[y0 * stride + x1] -
                        sum[y1 * stride + x0] + sum[y0 * stride + x0];
                    const area: i64 = @intCast((x1 - x0) * (y1 - y0));
                    const pure = if (color == 1) (cnt == area) else (cnt == 0);
                    if (pure) mch += 1 else break;
                }

                var mw: u32 = mcw * CELL;
                var mh: u32 = mch * CELL;
                if (x + mw > w) mw = w - x;
                if (yy + mh > h) mh = h - yy;

                // Mark visited.
                var my = cy;
                while (my < cy + mch) : (my += 1) {
                    var mx = cx;
                    while (mx < cx + mcw) : (mx += 1) {
                        visited[my * gw + mx] = 1;
                    }
                }

                if (mw >= self.hero_min and mh >= self.hero_min) {
                    // Hero block: pure white or black, no matching needed.
                    try manifest.append(self.allocator, .{
                        .x = @intCast(x),
                        .y = @intCast(yy),
                        .w = @intCast(mw),
                        .h = @intCast(mh),
                        .op_id = if (color == 1) -2 else -1,
                        .page_idx = -1,
                    });
                    n += 1;
                } else {
                    // Non-hero: record spec for feature extraction.
                    try specs.append(self.allocator, .{
                        .x = @intCast(x),
                        .y = @intCast(yy),
                        .w = @intCast(mw),
                        .h = @intCast(mh),
                        .manifest_idx = n,
                    });
                    try manifest.append(self.allocator, .{
                        .x = @intCast(x),
                        .y = @intCast(yy),
                        .w = @intCast(mw),
                        .h = @intCast(mh),
                        .op_id = -1,
                        .page_idx = -1,
                    });
                    n += 1;
                }
            }
        }

        return specs;
    }

    // -------------------------------------------------------------------
    // Feature extraction + matching pipeline
    // -------------------------------------------------------------------

    /// Extract features for non-hero tiles and match against the library.
    /// Updates manifest entries in-place with matched op_id and page_idx.
    fn extractAndMatch(
        self: *Arranger,
        gray: []const u8,
        color_pixels: []const u8,
        color_stride: u32,
        w: u32,
        _: u32,
        db: *const FeatureDB,
        reg: *const Registry,
        specs: *std.ArrayList(TileSpec),
        manifest: *std.ArrayList(Inst),
        tiles_buf: *std.ArrayList(u8),
        t: *Timings,
    ) !void {
        if (specs.items.len == 0) return;

        const feat_len: usize = db.feat_len;
        const n_specs = specs.items.len;

        // ── Phase 2: Pre-allocate feature buffer for all tiles ──────
        const feat_bufs_len = n_specs * feat_len;
        var feat_bufs = try self.allocator.alloc(u8, feat_bufs_len);
        defer self.allocator.free(feat_bufs);

        // ── Phase 3: Coarse cache check + full feature extraction ───
        // Ensure coarse_hit buffer.
        if (self.bufs.coarse_hit == null or self.bufs.coarse_hit.?.len < n_specs) {
            if (self.bufs.coarse_hit) |ch| self.allocator.free(ch);
            self.bufs.coarse_hit = try self.allocator.alloc(i32, n_specs);
        }
        const coarse_hit = self.bufs.coarse_hit.?;
        for (coarse_hit) |*ch| ch.* = -1;

        // Extract coarse features and check coarse cache.
        for (specs.items, 0..) |*sp, i| {
            const sp_w: u32 = @intCast(sp.w);
            const sp_h: u32 = @intCast(sp.h);

            // Build a crop buffer for this tile.
            const crop_len: usize = @as(usize, sp_w) * sp_h * db.channels;
            var crop_buf = try self.allocator.alloc(u8, crop_len);
            defer self.allocator.free(crop_buf);

            if (db.channels == 3) {
                for (0..@as(usize, @intCast(sp.h))) |row| {
                    const src_y = @as(u32, @intCast(sp.y)) + @as(u32, @intCast(row));
                    const src_offset = @as(usize, src_y) * color_stride + @as(usize, @as(u32, @intCast(sp.x))) * 3;
                    const dst_offset = row * sp_w * 3;
                    @memcpy(crop_buf[dst_offset..][0 .. sp_w * 3], color_pixels[src_offset..][0 .. sp_w * 3]);
                }
            } else {
                for (0..@as(usize, @intCast(sp.h))) |row| {
                    const src_y = @as(u32, @intCast(sp.y)) + @as(u32, @intCast(row));
                    const src_offset = @as(usize, src_y) * w + @as(usize, @as(u32, @intCast(sp.x)));
                    const dst_offset = row * sp_w;
                    @memcpy(crop_buf[dst_offset..][0..sp_w], gray[src_offset..][0..sp_w]);
                }
            }

            // Compute coarse feature: area-resample to scales[0] × scales[0].
            const N: u32 = self.scales[0];
            var coarse_feat = try self.allocator.alloc(u8, @as(usize, N) * N);
            defer self.allocator.free(coarse_feat);

            const sw = sp_w;
            const sh = sp_h;
            const maxv: u32 = (@as(u32, 1) << @intCast(self.G)) - 1;

            for (0..N) |dy| {
                const sy0: u32 = @intCast(@as(u64, dy) * sh / N);
                var sy1: u32 = @intCast(@as(u64, dy + 1) * sh / N);
                if (sy1 > sh) sy1 = sh;
                for (0..N) |dx| {
                    const sx0: u32 = @intCast(@as(u64, dx) * sw / N);
                    var sx1: u32 = @intCast(@as(u64, dx + 1) * sw / N);
                    if (sx1 > sw) sx1 = sw;
                    var psum: u64 = 0;
                    var sy = sy0;
                    while (sy < sy1) : (sy += 1) {
                        var sx = sx0;
                        while (sx < sx1) : (sx += 1) {
                            if (db.channels == 3) {
                                const offset = @as(usize, sy) * sp_w * 3 + sx * 3;
                                psum += (@as(u64, 29) * crop_buf[offset] +
                                    150 * crop_buf[offset + 1] +
                                    77 * crop_buf[offset + 2]) >> 8;
                            } else {
                                psum += crop_buf[@as(usize, sy) * sw + sx];
                            }
                        }
                    }
                    const area: u32 = (sy1 - sy0) * (sx1 - sx0);
                    const v: u32 = if (area > 0) @intCast(psum / area) else 0;
                    const q: u32 = if (self.G >= 8) v else (v * maxv + 127) / 255;
                    coarse_feat[dy * N + dx] = @intCast(@min(q, maxv));
                }
            }

            // Check coarse cache.
            const ch = coarseFeatHash(coarse_feat);
            if (self.coarse_cache.lookup(ch)) |pid| {
                coarse_hit[i] = pid;
                continue;
            }

            // Compute full multi-resolution feature.
            var crop_img = Img{
                .w = sp_w,
                .h = sp_h,
                .stride = sp_w * db.channels,
                .channels = db.channels,
                .pixels = crop_buf,
                .allocator = self.allocator,
            };
            try imgops.computeFeatureMultires(
                &crop_img,
                self.scales,
                self.G,
                self.has_edges,
                db.channels == 3,
                feat_bufs[i * feat_len ..][0..feat_len],
            );
        }

        // Process coarse-cache hits (fast path — no full feature needed).
        for (coarse_hit, 0..) |pid, i| {
            if (pid >= 0) {
                t.hits += 1;
                const midx = specs.items[i].manifest_idx;
                manifest.items[midx].op_id = pid;
                manifest.items[midx].page_idx = reg.entries[@intCast(pid)].page_idx;
            }
        }

        // ── Phase 4: Full-cache lookup for remaining tiles ───────────
        self.miss_idx.clearRetainingCapacity();

        for (specs.items, 0..) |*sp, i| {
            if (coarse_hit[i] >= 0) continue;
            const feat = feat_bufs[i * feat_len ..][0..feat_len];
            const fh = fullFeatHash(feat);
            if (self.full_cache.lookup(fh)) |pid| {
                t.hits += 1;
                const midx = sp.manifest_idx;
                manifest.items[midx].op_id = pid;
                manifest.items[midx].page_idx = reg.entries[@intCast(pid)].page_idx;
            } else {
                try self.miss_idx.append(self.allocator, i);
                // Copy feature into tiles buffer for batch matching.
                try tiles_buf.appendSlice(self.allocator, feat);
            }
        }

        // ── Phase 5: Batch match + cache_put ─────────────────────────
        if (self.miss_idx.items.len > 0) {
            const nt: u32 = @intCast(self.miss_idx.items.len);
            const coarse_for_match = self.coarse_len;

            const results = try match_mod.matchBatchCoarse(
                self.allocator,
                db.data,
                tiles_buf.items[0 .. @as(usize, nt) * feat_len],
                db.n_pages,
                nt,
                @intCast(feat_len),
                coarse_for_match,
            );
            defer self.allocator.free(results);

            for (results, 0..) |pid, i| {
                const midx = specs.items[self.miss_idx.items[i]].manifest_idx;
                manifest.items[midx].op_id = pid;
                manifest.items[midx].page_idx = reg.entries[@intCast(pid)].page_idx;

                // Populate both caches.
                const feat = tiles_buf.items[i * feat_len ..][0..feat_len];
                try self.full_cache.put(fullFeatHash(feat), pid);
                try self.coarse_cache.put(coarseFeatHash(feat[0..coarse_for_match]), pid);
            }

            t.match_time += 0; // TODO: would need timer
            t.tiles += nt;
        }
    }

    // -------------------------------------------------------------------
    // Public API: process a single frame
    // -------------------------------------------------------------------

    /// Process a single grayscale frame. Returns a list of Inst for the
    /// manifest. The caller owns the returned ArrayList and must deinit it.
    pub fn processFrame(
        self: *Arranger,
        gray: []const u8,
        color_pixels: []const u8,
        color_stride: u32,
        w: u32,
        h: u32,
        db: *const FeatureDB,
        reg: *const Registry,
        t: *Timings,
    ) !std.ArrayList(Inst) {
        var manifest: std.ArrayList(Inst) = .empty;
        errdefer manifest.deinit(self.allocator);

        var tiles_buf: std.ArrayList(u8) = .empty;
        defer tiles_buf.deinit(self.allocator);

        var specs = try self.solveGreedy(gray, w, h, &manifest);
        defer specs.deinit(self.allocator);

        try self.extractAndMatch(
            gray,
            color_pixels,
            color_stride,
            w,
            h,
            db,
            reg,
            &specs,
            &manifest,
            &tiles_buf,
            t,
        );

        return manifest;
    }

    /// Find the white and black hero pages in the library.
    /// These are the pages with the highest and lowest mean intensity at
    /// the coarsest scale level.
    pub fn findHeroPages(db: *const FeatureDB) struct { white: i32, black: i32 } {
        const hero_feat_len = db.scales[0] * db.scales[0];
        var pid_white: i32 = 0;
        var pid_black: i32 = 0;
        var mx: f64 = -1;
        var mn: f64 = 256;

        for (0..db.n_pages) |i| {
            var s: f64 = 0;
            const f = db.data[i * db.feat_len ..][0..hero_feat_len];
            for (f) |v| s += @floatFromInt(v);
            const m = s / @as(f64, @floatFromInt(hero_feat_len));
            if (m > mx) {
                mx = m;
                pid_white = @intCast(i);
            }
            if (m < mn) {
                mn = m;
                pid_black = @intCast(i);
            }
        }

        return .{ .white = pid_white, .black = pid_black };
    }
};

// ---------------------------------------------------------------------------
// Manifest I/O
// ---------------------------------------------------------------------------

/// Write a binary manifest for a single frame.
/// Format: uint32 src_w, src_h, n; then n × (6 × int32) records.
pub fn writeManifest(
    dir: []const u8,
    frame_idx: u32,
    src_w: u32,
    src_h: u32,
    manifest: []const Inst,
    io: std.Io,
) !void {
    // Ensure output directory exists.
    std.Io.Dir.cwd().createDir(io, dir, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Build filename: <dir>/NNNN.bin
    var buf: [256]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "{s}/{:0>4}.bin", .{ dir, frame_idx }) catch return error.NameTooLong;

    const file = try std.Io.Dir.cwd().createFile(io, name, .{});
    defer file.close(io);

    var write_buf: [4096]u8 = undefined;
    var fw = file.writer(io, &write_buf);

    // Header: src_w, src_h, n
    try fw.interface.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(u32, src_w)));
    try fw.interface.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(u32, src_h)));
    try fw.interface.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(u32, @intCast(manifest.len))));

    // Records
    for (manifest) |inst| {
        try fw.interface.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(i32, inst.x)));
        try fw.interface.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(i32, inst.y)));
        try fw.interface.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(i32, inst.w)));
        try fw.interface.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(i32, inst.h)));
        try fw.interface.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(i32, inst.op_id)));
        try fw.interface.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(i32, inst.page_idx)));
    }

    try fw.interface.flush();
}

/// Write the fps sidecar file so the renderer can auto-detect source frame rate.
pub fn writeFpsSidecar(dir: []const u8, fps: f64, io: std.Io) !void {
    std.Io.Dir.cwd().createDir(io, dir, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    var buf: [256]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "{s}/fps.bin", .{dir}) catch return error.NameTooLong;

    const file = try std.Io.Dir.cwd().createFile(io, name, .{});
    defer file.close(io);

    var write_buf: [4096]u8 = undefined;
    var fw = file.writer(io, &write_buf);
    try fw.interface.writeAll(std.mem.asBytes(&fps));
    try fw.interface.flush();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "fnv1a64: deterministic" {
    const a = fnv1a64("hello");
    const b = fnv1a64("hello");
    try std.testing.expectEqual(a, b);
    try std.testing.expect(a != 0); // never returns 0 (sentinel)
}

test "fnv1a64: different inputs produce different hashes" {
    const a = fnv1a64("hello");
    const b = fnv1a64("world");
    try std.testing.expect(a != b);
}

test "fullFeatHash: works on small input" {
    const data = [_]u8{ 10, 20, 30, 40, 50 };
    const h = fullFeatHash(&data);
    try std.testing.expect(h != 0);
}

test "coarseFeatHash: works on small input" {
    const data = [_]u8{ 10, 20, 30 };
    const h = coarseFeatHash(&data);
    try std.testing.expect(h != 0);
}

test "Cache: insert and lookup" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();

    try cache.put(fnv1a64("key1"), 42);
    try cache.put(fnv1a64("key2"), 99);

    const pid1 = cache.lookup(fnv1a64("key1"));
    try std.testing.expect(pid1 != null);
    try std.testing.expectEqual(@as(i32, 42), pid1.?);

    const pid2 = cache.lookup(fnv1a64("key2"));
    try std.testing.expect(pid2 != null);
    try std.testing.expectEqual(@as(i32, 99), pid2.?);

    const miss = cache.lookup(fnv1a64("missing"));
    try std.testing.expect(miss == null);
}

test "Cache: grows on high load" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();

    // Insert enough to trigger growth.
    var i: u32 = 0;
    while (i < 3000) : (i += 1) {
        var buf: [8]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch break;
        try cache.put(fnv1a64(s), i);
    }

    // All should be retrievable.
    i = 0;
    while (i < 3000) : (i += 1) {
        var buf: [8]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch break;
        const pid = cache.lookup(fnv1a64(s));
        try std.testing.expect(pid != null);
        try std.testing.expectEqual(@as(i32, i), pid.?);
    }
}

test "Cache: clear resets state" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();

    try cache.put(fnv1a64("key"), 1);
    cache.clear();
    try std.testing.expect(cache.lookup(fnv1a64("key")) == null);
}

test "writeManifest: creates file" {
    const manifest = [_]Inst{
        .{ .x = 0, .y = 0, .w = 64, .h = 64, .op_id = -2, .page_idx = -1 },
        .{ .x = 64, .y = 0, .w = 32, .h = 32, .op_id = 5, .page_idx = 10 },
    };

    try writeManifest("/tmp/badziggle_test", 0, 1920, 1080, &manifest, std.testing.io);

    // Verify file exists and has correct size.
    // Header (12 bytes) + 2 records × 24 bytes = 60 bytes.
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, "/tmp/badziggle_test/0000.bin", .{});
    defer file.close(std.testing.io);
    const stat = try file.stat();
    try std.testing.expectEqual(@as(u64, 60), stat.size);

    // Clean up.
    std.Io.Dir.cwd().deleteFile(std.testing.io, "/tmp/badziggle_test/0000.bin") catch {};
    std.Io.Dir.cwd().deleteDir(std.testing.io, "/tmp/badziggle_test") catch {};
}
