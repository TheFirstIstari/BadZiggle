const std = @import("std");

/// Universal image buffer - equivalent to C's Img struct
pub const Img = struct {
    w: u32,
    h: u32,
    stride: u32,
    channels: u32, // 1 or 3
    pixels: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, w: u32, h: u32, channels: u32) !Img {
        const stride = w * channels;
        const pixels = try allocator.alloc(u8, stride * h);
        return Img{
            .w = w,
            .h = h,
            .stride = stride,
            .channels = channels,
            .pixels = pixels,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Img) void {
        self.allocator.free(self.pixels);
    }

    pub fn pixelAt(self: *const Img, x: u32, y: u32) []u8 {
        const offset = y * self.stride + x * self.channels;
        return self.pixels[offset .. offset + self.channels];
    }
};

/// Feature database from features.bin
pub const FeatureDB = struct {
    n_pages: u32,
    feat_len: u32,
    G: u32, // bits per cell (1-8)
    n_scales: u32,
    scales: []u32,
    has_edges: bool,
    channels: u32, // 1 or 3
    data: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FeatureDB) void {
        self.allocator.free(self.scales);
        self.allocator.free(self.data);
    }
};

/// Registry entry from registry.bin
pub const RegEntry = struct {
    page_idx: i32,
    pdf_path: []const u8,
};

/// Registry - source file mapping
pub const Registry = struct {
    entries: []RegEntry,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Registry) void {
        for (self.entries) |entry| {
            self.allocator.free(entry.pdf_path);
        }
        self.allocator.free(self.entries);
    }
};

/// Per-tile instruction
pub const Inst = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    op_id: i32, // -2=white, -1=black, or library index
    page_idx: i32,
};

/// System configuration
pub const SystemConfig = struct {
    total_memory_bytes: u64,
    cpu_cores: u32,
    num_threads: u32,
    cache_budget_bytes: u64,
    cache_enabled: bool,
};

// ---------------------------------------------------------------------------
// FeatureDB / Registry binary loaders
// ---------------------------------------------------------------------------

pub const LoadError = error{
    FileOpenFailed,
    FileReadFailed,
    InvalidHeader,
    InvalidData,
    OutOfMemory,
};

/// Load a features.bin file.
///
/// Binary format (little-endian):
///   [0..4]   u32 n_pages
///   [4..8]   u32 feat_len
///   [8..12]  u32 G (bits per cell, 1–8)
///   [12..16] u32 n_scales
///   [16..]   n_scales × u32 scale values
///   [..]     u32 has_edges
///   [..]     u32 channels (optional, present when feat_len implies color)
///   [..]     n_pages × feat_len bytes of feature data
pub fn loadFeatures(allocator: std.mem.Allocator, path: []const u8, io: std.Io) LoadError!FeatureDB {
    const buf = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 40)) catch return error.FileReadFailed;
    defer allocator.free(buf);

    if (buf.len < 24) return error.InvalidHeader;

    const n_pages = std.mem.readInt(u32, buf[0..4], .little);
    const feat_len = std.mem.readInt(u32, buf[4..8], .little);
    const G = std.mem.readInt(u32, buf[8..12], .little);
    const n_scales = std.mem.readInt(u32, buf[12..16], .little);

    if (G == 0 or G > 8 or n_scales == 0 or n_scales > 16) return error.InvalidHeader;

    const header_len: usize = 16 + @as(usize, n_scales) * 4 + 4;
    if (buf.len < header_len) return error.InvalidHeader;

    // Read scale array.
    const scales = try allocator.alloc(u32, n_scales);
    errdefer allocator.free(scales);
    for (0..n_scales) |i| {
        const s = std.mem.readInt(u32, buf[16 + i * 4 ..][0..4], .little);
        if (s == 0 or s > 256) {
            allocator.free(scales);
            return error.InvalidData;
        }
        scales[i] = s;
    }

    const has_edges_val = std.mem.readInt(u32, buf[16 + n_scales * 4 ..][0..4], .little) != 0;

    // Detect channels from feat_len.
    var gray_feat_len: usize = 0;
    for (scales) |s| {
        gray_feat_len += @as(usize, s) * s;
    }
    const expected_gray = gray_feat_len * (if (has_edges_val) @as(usize, 2) else @as(usize, 1));
    const expected_color = gray_feat_len * (1 + (if (has_edges_val) @as(usize, 1) else @as(usize, 0)) + 3);

    var detected_channels: u32 = 0;
    var data_offset = header_len;
    if (feat_len == expected_gray) {
        detected_channels = 1;
    } else if (feat_len == expected_color) {
        detected_channels = 3;
        // Try to read the channels field from header if present.
        if (buf.len >= header_len + 4) {
            const ch = std.mem.readInt(u32, buf[header_len..][0..4], .little);
            if (ch == 3) data_offset = header_len + 4;
        }
    } else {
        allocator.free(scales);
        return error.InvalidData;
    }

    const data_len = @as(usize, n_pages) * @as(usize, feat_len);
    if (data_offset + data_len > buf.len) {
        allocator.free(scales);
        return error.InvalidData;
    }

    const data = try allocator.alloc(u8, data_len);
    errdefer allocator.free(data);
    @memcpy(data, buf[data_offset..][0..data_len]);

    return FeatureDB{
        .n_pages = n_pages,
        .feat_len = feat_len,
        .G = G,
        .n_scales = n_scales,
        .scales = scales,
        .has_edges = has_edges_val,
        .channels = detected_channels,
        .data = data,
        .allocator = allocator,
    };
}

/// Load a registry.bin file.
///
/// Binary format (little-endian):
///   [0..4]   u32 n (number of entries)
///   per entry:
///     [..]     i32 page_idx
///     [..]     u32 path_len
///     [..]     path_len bytes of UTF-8 path
pub fn loadRegistry(allocator: std.mem.Allocator, path: []const u8, io: std.Io) LoadError!Registry {
    const buf = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 40)) catch return error.FileReadFailed;
    defer allocator.free(buf);

    if (buf.len < 4) return error.InvalidHeader;

    const n = std.mem.readInt(u32, buf[0..4], .little);
    if (n > buf.len / 5) return error.InvalidData;

    const entries = try allocator.alloc(RegEntry, n);
    errdefer {
        for (entries) |e| allocator.free(e.pdf_path);
        allocator.free(entries);
    }

    var off: usize = 4;
    for (0..n) |i| {
        if (off + 8 > buf.len) return error.InvalidData;

        const page_idx = std.mem.readInt(i32, buf[off..][0..4], .little);
        off += 4;
        const plen = std.mem.readInt(u32, buf[off..][0..4], .little);
        off += 4;

        if (off + plen > buf.len) return error.InvalidData;

        const p = try allocator.alloc(u8, plen);
        errdefer allocator.free(p);
        @memcpy(p, buf[off..][0..plen]);
        off += plen;

        entries[i] = .{
            .page_idx = page_idx,
            .pdf_path = p,
        };
    }

    return Registry{
        .entries = entries,
        .allocator = allocator,
    };
}

/// CLI options
pub const Options = struct {
    input: []const u8 = "",
    output: []const u8 = "",
    video: []const u8 = "",
    features: []const u8 = "",
    registry: []const u8 = "",
    manifests: []const u8 = "",
    library: []const u8 = "",
    preset: []const u8 = "",
    width: u32 = 1920,
    height: u32 = 1080,
    max_frames: u32 = 0,
    threads: u32 = 0,
    bits: u32 = 1,
    no_edges: bool = false,
    color: bool = false,
    scales: []const u32 = &.{},
    channels: u32 = 1,
    verbose: bool = false,
};