const std = @import("std");
const cli = @import("cli.zig");
const types = @import("types.zig");

const VERSION = "0.1.0";

fn printHelp() void {
    cli.info("badziggle v{s} — tiled video encoder using PDF/image library matching", .{VERSION});
    cli.info("", .{});
    cli.info("Usage:", .{});
    cli.info("  badziggle <command> [options]", .{});
    cli.info("", .{});
    cli.info("Commands:", .{});
    cli.info("  arrange  — decode video, match tiles against library, write manifests", .{});
    cli.info("  render   — assemble frames from manifests, encode output video", .{});
    cli.info("  build    — build source library (features.bin + registry.bin) from PDFs/images", .{});
    cli.info("  <input> <output>  (shorthand for arrange+render pipeline)", .{});
    cli.info("", .{});
    cli.info("Run 'badziggle <command> --help' for command-specific options.", .{});
}

fn printArrangeHelp() void {
    cli.info("badziggle arrange — decode video, match tiles, write manifests", .{});
    cli.info("", .{});
    cli.info("Usage:", .{});
    cli.info("  badziggle arrange --video <file> [options]", .{});
    cli.info("", .{});
    cli.info("Options:", .{});
    cli.info("  --video <file>         Input video file (required)", .{});
    cli.info("  --features <file>      Feature database (default: features.bin)", .{});
    cli.info("  --registry <file>      Registry (default: registry.bin)", .{});
    cli.info("  --manifests <dir>      Manifest output directory (default: manifests_greedy)", .{});
    cli.info("  --max-block-pct <N>    Maximum block size as percentage of frame (default: auto)", .{});
    cli.info("  --hero-min-pct <N>     Minimum hero block size as percentage of frame (default: auto)", .{});
    cli.info("  --max-frames <N>       Maximum frames to process (0 = all)", .{});
    cli.info("  --threads <N>          Thread count (0 = auto)", .{});
    cli.info("  --verbose, -v          Verbose output", .{});
    cli.info("  --quiet, -q            Suppress non-error output", .{});
    cli.info("  --json                 Machine-readable JSON output", .{});
}

fn printRenderHelp() void {
    cli.info("badziggle render — assemble frames from manifests, encode output video", .{});
    cli.info("", .{});
    cli.info("Usage:", .{});
    cli.info("  badziggle render [options]", .{});
    cli.info("", .{});
    cli.info("Options:", .{});
    cli.info("  --manifests <dir>      Manifest directory (default: manifests_greedy)", .{});
    cli.info("  --registry <file>      Registry (default: registry.bin)", .{});
    cli.info("  --output <file>        Output video (default: output.mov)", .{});
    cli.info("  --width <N>            Output width (overrides preset)", .{});
    cli.info("  --height <N>           Output height (overrides preset)", .{});
    cli.info("  --fps <N>              Output FPS (overrides preset)", .{});
    cli.info("  --preset <name>        Resolution preset: 8k, 4k, 1080p, 720p", .{});
    cli.info("  --channels <N>         1=grayscale, 3=color (default: 1)", .{});
    cli.info("  --max-frames <N>       Maximum frames to render (0 = all)", .{});
    cli.info("  --threads <N>          Thread count (0 = auto)", .{});
    cli.info("  --verbose, -v          Verbose output", .{});
    cli.info("  --quiet, -q            Suppress non-error output", .{});
    cli.info("  --json                 Machine-readable JSON output", .{});
}

fn printBuildHelp() void {
    cli.info("badziggle build — build source library from PDFs and images", .{});
    cli.info("", .{});
    cli.info("Usage:", .{});
    cli.info("  badziggle build <sources_dir> [options]", .{});
    cli.info("", .{});
    cli.info("Options:", .{});
    cli.info("  --bits <N>             Bits per cell G, 1-8 (default: 1)", .{});
    cli.info("  --no-edges             Disable edge detection features", .{});
    cli.info("  --color                Include BGR color features", .{});
    cli.info("  --scales <list>        Comma-separated scale levels (default: 32,64,128)", .{});
    cli.info("  --out <file>           Output features file (default: features.bin)", .{});
    cli.info("  --threads <N>          Thread count (0 = auto)", .{});
    cli.info("  --verbose, -v          Verbose output", .{});
    cli.info("  --quiet, -q            Suppress non-error output", .{});
    cli.info("  --json                 Machine-readable JSON output", .{});
}

/// Resolve library path: check --library, then features.bin/registry.bin in cwd,
/// then ~/.badziggle/library/, then fall back to cwd.
fn resolveLibraryPath(opts: *types.Options) void {
    if (opts.library.len > 0) return; // already set

    // Check if features.bin + registry.bin exist in current directory
    if (std.c.access("features.bin", 0) == 0 and
        std.c.access("registry.bin", 0) == 0) {
        opts.library = ".";
        return;
    }

    // Try ~/.badziggle/library/
    const home_c = std.c.getenv("HOME") orelse return;
    const home = std.mem.span(home_c);

    // Single allocation: construct null-terminated path for c.access.
    // The null byte at the end serves both the C access check and
    // can be reused as the path sentinel for opts.library.
    const suffix = ".badziggle/library";
    const buf_len = home.len + 1 + suffix.len + 1; // +1 for '/', +1 for null
    const default_lib = cli.g_allocator.alloc(u8, buf_len) catch return;

    var off: usize = 0;
    @memcpy(default_lib[off..][0..home.len], home);
    off += home.len;
    default_lib[off] = '/';
    off += 1;
    @memcpy(default_lib[off..][0..suffix.len], suffix);
    off += suffix.len;
    default_lib[off] = 0; // null terminator for c.access

    // c.access requires a null-terminated C string.
    if (std.c.access(@ptrCast(default_lib.ptr), 0) == 0) {
        opts.library = default_lib[0..off]; // transfer ownership (strip null)
        return;
    }

    cli.g_allocator.free(default_lib);
}

/// Expand a preset name to width/height. Returns true if the preset was recognized.
fn expandPreset(opts: *types.Options) bool {
    if (opts.preset.len == 0) return false;

    var w: u32 = 0;
    var h: u32 = 0;
    if (std.mem.eql(u8, opts.preset, "8k")) { w = 7680; h = 4320; }
    else if (std.mem.eql(u8, opts.preset, "4k")) { w = 3840; h = 2160; }
    else if (std.mem.eql(u8, opts.preset, "1080p")) { w = 1920; h = 1080; }
    else if (std.mem.eql(u8, opts.preset, "720p")) { w = 1280; h = 720; }
    else {
        cli.warn("unknown preset '{s}', using defaults", .{opts.preset});
        return false;
    }

    opts.width = w;
    opts.height = h;
    return true;
}

/// Run the arrange subcommand.
fn runArrange(opts: *types.Options) !u8 {
    cli.info("badziggle arrange — starting", .{});

    if (opts.video.len == 0) {
        cli.die("--video is required for arrange", .{});
    }

    resolveLibraryPath(opts);

    // TODO: call arrange.main() from arrange.zig
    // For now, just validate the options and print what we'd do
    cli.info("video: {s}", .{opts.video});
    cli.info("library: {s}", .{opts.library});
    cli.info("features: {s}", .{opts.features});
    cli.info("registry: {s}", .{opts.registry});
    cli.info("manifests: {s}", .{opts.manifests});
    cli.info("max_frames: {d}", .{opts.max_frames});
    cli.info("width: {d}, height: {d}", .{ opts.width, opts.height });

    return 0;
}

/// Run the render subcommand.
fn runRender(opts: types.Options) !u8 {
    cli.info("badziggle render — starting", .{});

    cli.info("manifests: {s}", .{opts.manifests});
    cli.info("output: {s}", .{opts.output});
    cli.info("width: {d}, height: {d}", .{ opts.width, opts.height });
    cli.info("channels: {d}", .{opts.channels});
    cli.info("max_frames: {d}", .{opts.max_frames});

    return 0;
}

/// Run the build subcommand.
fn runBuild(opts: types.Options, sources_dir: []const u8) !u8 {
    cli.info("badziggle build — starting", .{});

    if (sources_dir.len == 0) {
        cli.die("sources_dir is required for build", .{});
    }

    cli.info("sources_dir: {s}", .{sources_dir});
    cli.info("out: {s}", .{opts.output});
    cli.info("bits: {d}", .{opts.bits});
    cli.info("scales: {d} levels", .{opts.scales.len});
    cli.info("color: {d}", .{@as(u32, if (opts.color) 1 else 0)});
    cli.info("edges: {d}", .{@as(u32, if (opts.no_edges) 0 else 1)});

    return 0;
}

/// Detect source video dimensions and fps to auto-set output width/height.
fn autoDetectSource(video_path: []const u8, opts: *types.Options) void {
    _ = video_path;
    if (opts.width == 0) opts.width = 1920;
    if (opts.height == 0) opts.height = 1080;
}

/// Convert slice of null-terminated strings to regular string slice.
fn cStrVectorToSlice(allocator: std.mem.Allocator, vec: []const [*:0]const u8) ![][]const u8 {
    var result = try allocator.alloc([]const u8, vec.len);
    for (vec, 0..) |ptr, i| {
        result[i] = std.mem.span(ptr);
    }
    return result;
}

pub fn main(init: std.process.Init.Minimal) u8 {
    const allocator = std.heap.page_allocator;
    cli.g_allocator = allocator;
    cli.init(allocator);

    const raw_args = init.args.vector;
    const args = cStrVectorToSlice(allocator, raw_args) catch {
        return 1;
    };
    defer allocator.free(args);

    if (args.len < 2) {
        printHelp();
        return 1;
    }

    const cmd = args[1];

    // Parse global flags first (--verbose, --quiet, --json, --threads)
    cli.parse(args[1..]);

    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        printHelp();
        return 0;
    }

    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-V")) {
        cli.info("badziggle v{s}", .{VERSION});
        return 0;
    }

    if (std.mem.eql(u8, cmd, "arrange")) {
        if (cli.has("help")) {
            printArrangeHelp();
            return 0;
        }
        var opts = cli.buildOptions();
        const preset_expanded = expandPreset(&opts);
        _ = preset_expanded;
        return runArrange(&opts) catch 1;
    }

    if (std.mem.eql(u8, cmd, "render")) {
        if (cli.has("help")) {
            printRenderHelp();
            return 0;
        }
        const opts = cli.buildOptions();
        return runRender(opts) catch 1;
    }

    if (std.mem.eql(u8, cmd, "build") or std.mem.eql(u8, cmd, "build-library")) {
        if (cli.has("help")) {
            printBuildHelp();
            return 0;
        }
        const opts = cli.buildOptions();

        // Get sources_dir from positional arg after "build"
        var sources_dir: []const u8 = "";
        for (args[2..]) |arg| {
            if (arg.len > 0 and arg[0] != '-') {
                sources_dir = arg;
                break;
            }
        }

        return runBuild(opts, sources_dir) catch 1;
    }

    // Shorthand: <input> <output> [options] — auto-detect as arrange+render pipeline
    if (args.len >= 4) {
        // Check if args[2] doesn't start with '-' (it's a positional output arg)
        const input_arg = args[2];
        const output_arg = args[3];
        if (input_arg.len > 0 and input_arg[0] != '-' and output_arg.len > 0 and output_arg[0] != '-') {
            cli.info("badziggle shorthand encode: {s} -> {s}", .{ input_arg, output_arg });
            // TODO: run arrange then render pipeline
            return 0;
        }
    }

    cli.err("unknown command '{s}'", .{cmd});
    cli.info("Run 'badziggle help' for usage.", .{});
    return 1;
}
