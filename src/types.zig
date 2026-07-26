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