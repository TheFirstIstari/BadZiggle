const std = @import("std");
const Options = @import("types.zig").Options;

/// Global CLI context — mirrors C's CLICtx / g_cli.
pub const Context = struct {
    verbose: bool = false,
    quiet: bool = false,
    json: bool = false,
    threads: u32 = 0, // 0 = auto-detect
};

/// Simple option store — flat key/value pairs.
const MaxOpts = 128;
const OptEntry = struct { name: []const u8, value: []const u8 };

/// Module-level state (equivalent to C's globals).
var g_ctx = Context{};
var g_opts: [MaxOpts]OptEntry = undefined;
var g_nopts: usize = 0;
var g_last_progress: f64 = -1.0;
pub var g_allocator: std.mem.Allocator = undefined;

/// Initialise the CLI module. Must be called once before any other function.
pub fn init(allocator: std.mem.Allocator) void {
    g_ctx = Context{};
    g_nopts = 0;
    g_last_progress = -1.0;
    g_allocator = allocator;
}

/// Return a read-only reference to the current context.
pub fn ctx() Context {
    return g_ctx;
}

pub fn setThreads(n: u32) void {
    if (n > 0) g_ctx.threads = n;
}

// -------------------------------------------------------------------
//  Option store
// -------------------------------------------------------------------

pub fn store(name: []const u8, value: []const u8) void {
    // Update existing entry.
    for (g_opts[0..g_nopts]) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            entry.value = value;
            return;
        }
    }
    // Append new entry.
    if (g_nopts < MaxOpts) {
        g_opts[g_nopts] = .{ .name = name, .value = value };
        g_nopts += 1;
    }
}

fn get(name: []const u8, def: []const u8) []const u8 {
    for (g_opts[0..g_nopts]) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.value;
    }
    return def;
}

// -------------------------------------------------------------------
//  Public option accessors
// -------------------------------------------------------------------

pub fn optStr(name: []const u8, def: []const u8) []const u8 {
    return get(name, def);
}

pub fn optInt(name: []const u8, def: i64) i64 {
    const v = get(name, "");
    if (v.len == 0) return def;
    return std.fmt.parseInt(i64, v, 10) catch def;
}

pub fn optFloat(name: []const u8, def: f64) f64 {
    const v = get(name, "");
    if (v.len == 0) return def;
    return std.fmt.parseFloat(f64, v) catch def;
}

pub fn optBool(name: []const u8, def: bool) bool {
    for (g_opts[0..g_nopts]) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }
    return def;
}

pub fn has(name: []const u8) bool {
    for (g_opts[0..g_nopts]) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

// -------------------------------------------------------------------
//  Argument parser
// -------------------------------------------------------------------

pub fn parse(args: []const []const u8) void {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        // --  (POSIX end-of-flags separator)
        if (arg.len == 2 and arg[0] == '-' and arg[1] == '-') continue;

        // Flags starting with '-'
        if (arg.len > 0 and arg[0] != '-') continue;
        if (arg.len == 1) continue; // bare "-"

        if (arg.len == 2 and arg[1] != '-') {
            // Short flag: -X  (e.g. -v, -q)
            const short = arg[1];
            if (short == 'v') {
                g_ctx.verbose = true;
            } else if (short == 'q') {
                g_ctx.quiet = true;
            } else if (short == 'j') {
                g_ctx.json = true;
            } else if (i + 1 < args.len and args[i + 1][0] != '-') {
                i += 1;
                g_ctx.threads = std.fmt.parseInt(u32, args[i], 10) catch 0;
            } else {
                store(arg[1..2], "1");
            }
            continue;
        }

        if (arg[1] == '-') {
            // Long flag: --key[=value]  or  --key value
            const rest = arg[2..];

            // Check common single-word flags first (most likely)
            if (rest.len == 0) continue;
            const first_c = rest[0];

            if (first_c == 't' and rest.len >= 4) {
                if (std.mem.eql(u8, rest, "threads=")) {
                    g_ctx.threads = std.fmt.parseInt(u32, rest["threads=".len..], 10) catch 0;
                    continue;
                }
                if (std.mem.eql(u8, rest, "threads") and i + 1 < args.len) {
                    i += 1;
                    g_ctx.threads = std.fmt.parseInt(u32, args[i], 10) catch 0;
                    continue;
                }
            }

            if (first_c == 'v' and rest.len == 7 and std.mem.eql(u8, rest, "verbose")) {
                g_ctx.verbose = true;
                continue;
            }
            if (first_c == 'q' and rest.len == 5 and std.mem.eql(u8, rest, "quiet")) {
                g_ctx.quiet = true;
                continue;
            }
            if (first_c == 'j' and rest.len == 4 and std.mem.eql(u8, rest, "json")) {
                g_ctx.json = true;
                continue;
            }

            // --key=value  or  --key value
            if (std.mem.indexOfScalar(u8, rest, '=')) |eq| {
                store(rest[0..eq], rest[eq + 1 ..]);
            } else if (i + 1 < args.len and args[i + 1][0] != '-') {
                i += 1;
                store(rest, args[i]);
            } else {
                store(rest, "1");
            }
            continue;
        }

        // Single-dash prefixed but not a short flag (e.g. -abc)
        var j: usize = 1;
        while (j < arg.len) : (j += 1) {
            const name = arg[j .. j + 1];
            if (j + 1 < arg.len and arg[j + 1] == '=') {
                store(name, arg[j + 2 ..]);
                break;
            } else if (i + 1 < args.len and args[i + 1][0] != '-') {
                i += 1;
                store(name, args[i]);
                break;
            } else {
                store(name, "1");
            }
        }
    }
}

// -------------------------------------------------------------------
//  Output helpers — Zig 0.16 compatible (uses std.debug.print for stderr)
// -------------------------------------------------------------------

pub fn info(comptime fmt: []const u8, args: anytype) void {
    if (g_ctx.quiet) return;
    std.debug.print("[info] " ++ fmt ++ "\n", args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[warn] " ++ fmt ++ "\n", args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[error] " ++ fmt ++ "\n", args);
}

pub fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("[fatal] " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

// -------------------------------------------------------------------
//  Progress reporting
// -------------------------------------------------------------------

pub fn progressFrame(label: []const u8, frame: u32, total_frames: u32, fps: f64, cache_hit_pct: f64) void {
    if (g_ctx.quiet or g_ctx.json) return;

    var pct: f64 = 0.0;
    if (total_frames > 0) pct = @as(f64, @floatFromInt(frame)) / @as(f64, @floatFromInt(total_frames)) * 100.0;

    // Throttle: only update if >= 1% change or first frame.
    if (pct - g_last_progress < 1.0 and g_last_progress >= 0.0) return;
    g_last_progress = pct;

    std.debug.print("[{s}] frame {d}/{d} ({d:.1}%) | {d:.1} fps | cache {d:.1}%\n", .{
        label, frame, total_frames, pct, fps, cache_hit_pct,
    });
}

pub fn progressStage(stage: []const u8, percent: u32) void {
    if (g_ctx.quiet or g_ctx.json) return;
    std.debug.print("[stage] {s}: {d}%\n", .{ stage, percent });
}

pub fn progressDone(summary: []const u8) void {
    if (g_ctx.quiet) return;
    std.debug.print("[done] {s}\n", .{summary});
}

// -------------------------------------------------------------------
//  JSON output helpers (minimal)
// -------------------------------------------------------------------

pub fn jsonEscape(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    // Fast path: check if escaping is needed at all.
    // Most CLI strings (flag names, values) don't need escaping.
    var needs_escape = false;
    for (input) |c| {
        if (c == '\\' or c == '"' or c < 0x20) {
            needs_escape = true;
            break;
        }
    }
    if (!needs_escape) return input;

    var result = std.ArrayList(u8).initCapacity(allocator, input.len + 2) catch return error.OutOfMemory;
    defer result.deinit();
    for (input) |c| {
        if (c == '\\' or c == '"') {
            try result.append('\\');
            try result.append(c);
        } else if (c < 0x20) {
            try result.writer().print("\\u{0:0>4}", .{c});
        } else {
            try result.append(c);
        }
    }
    return result.toOwnedSlice();
}

pub fn jsonStart() void {
    if (g_ctx.json) {
        std.debug.print("{{\n", .{});
    }
}

pub fn jsonField(name: []const u8, value: []const u8) void {
    if (!g_ctx.json) return;
    const ename = jsonEscape(g_allocator, name) catch name;
    defer if (!std.mem.eql(u8, ename, name)) g_allocator.free(ename);
    const evalue = jsonEscape(g_allocator, value) catch value;
    defer if (!std.mem.eql(u8, evalue, value)) g_allocator.free(evalue);
    std.debug.print("  \"{s}\": \"{s}\",\n", .{ ename, evalue });
}

pub fn jsonEnd() void {
    if (g_ctx.json) {
        std.debug.print("}}\n", .{});
    }
}

// -------------------------------------------------------------------
//  Build Options from parsed CLI state
// -------------------------------------------------------------------

pub fn buildOptions() Options {
    return Options{
        .input = optStr("input", ""),
        .output = optStr("output", ""),
        .video = optStr("video", ""),
        .features = optStr("features", ""),
        .registry = optStr("registry", ""),
        .manifests = optStr("manifests", ""),
        .library = optStr("library", ""),
        .preset = optStr("preset", ""),
        .width = @intCast(optInt("width", 1920)),
        .height = @intCast(optInt("height", 1080)),
        .max_frames = @intCast(optInt("max-frames", 0)),
        .threads = g_ctx.threads,
        .bits = @intCast(optInt("bits", 1)),
        .no_edges = optBool("no-edges", false),
        .color = optBool("color", false),
        .scales = parseScales(g_allocator, optStr("scales", "")),
        .channels = @intCast(optInt("channels", 1)),
        .verbose = g_ctx.verbose,
    };
}

/// Parse comma-separated scales string into a list of u32 values.
fn parseScales(allocator: std.mem.Allocator, scales_str: []const u8) []u32 {
    var result = std.ArrayList(u32).initCapacity(allocator, 16) catch return &.{};
    defer result.deinit(allocator);
    var it = std.mem.splitAny(u8, scales_str, ",");
    while (it.next()) |part| {
        if (part.len > 0) {
            const trimmed = std.mem.trim(u8, part, " \t");
            if (std.fmt.parseInt(u32, trimmed, 10)) |v| {
                result.append(allocator, v) catch break;
            } else |_| {}
        }
    }
    return result.toOwnedSlice(allocator) catch &.{};
}

// -------------------------------------------------------------------
//  Tests
// -------------------------------------------------------------------

test "init resets state" {
    init(std.testing.allocator);
    const c = ctx();
    try std.testing.expect(!c.verbose);
    try std.testing.expect(!c.quiet);
    try std.testing.expect(!c.json);
    try std.testing.expectEqual(@as(u32, 0), c.threads);
}

test "store and retrieve" {
    init(std.testing.allocator);
    store("foo", "bar");
    try std.testing.expectEqualStrings("bar", optStr("foo", ""));
    try std.testing.expectEqual(@as(i64, 42), optInt("missing", 42));
    store("num", "100");
    try std.testing.expectEqual(@as(i64, 100), optInt("num", 0));
    try std.testing.expect(has("foo"));
    try std.testing.expect(!has("nope"));
}

test "parse short flags" {
    init(std.testing.allocator);
    const args = &.{ "-v", "-q", "--threads=4" };
    parse(args);
    try std.testing.expect(ctx().verbose);
    try std.testing.expect(ctx().quiet);
    try std.testing.expectEqual(@as(u32, 4), ctx().threads);
}

test "parse long options" {
    init(std.testing.allocator);
    const args = &.{ "--verbose", "--json", "--threads", "8" };
    parse(args);
    try std.testing.expect(ctx().verbose);
    try std.testing.expect(ctx().json);
    try std.testing.expectEqual(@as(u32, 8), ctx().threads);
}

test "parse key=value" {
    init(std.testing.allocator);
    const args = &.{ "--input=video.mp4", "--width", "1280" };
    parse(args);
    try std.testing.expectEqualStrings("video.mp4", optStr("input", ""));
    try std.testing.expectEqual(@as(i64, 1280), optInt("width", 0));
}

test "setThreads" {
    init(std.testing.allocator);
    setThreads(4);
    try std.testing.expectEqual(@as(u32, 4), ctx().threads);
    setThreads(0); // should not change
    try std.testing.expectEqual(@as(u32, 4), ctx().threads);
}

test "store overwrites" {
    init(std.testing.allocator);
    store("k", "v1");
    store("k", "v2");
    try std.testing.expectEqualStrings("v2", optStr("k", ""));
}
