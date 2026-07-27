const std = @import("std");
const cli = @import("cli.zig");
const types = @import("types.zig");
const video = @import("video.zig");
const arrange = @import("arrange.zig");
const match = @import("match.zig");
const render = @import("render.zig");
const imgops = @import("imgops.zig");

const VERSION = "0.1.0";

fn nowNanos() u64 {
    var ts: std.c.timespec = undefined;
    const ok = std.c.clock_gettime(std.c.clockid_t.MONOTONIC, &ts);
    if (ok != 0) {
        return 0;
    }
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

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
fn runArrange(opts: *types.Options, io: std.Io) !u8 {
    cli.info("badziggle arrange — starting", .{});

    if (opts.video.len == 0) {
        cli.die("--video is required for arrange", .{});
    }

    resolveLibraryPath(opts);

    // Resolve feature and registry paths relative to library directory.
    const feat_path = resolveFilePath(opts.library, opts.features, "features.bin");
    const reg_path = resolveFilePath(opts.library, opts.registry, "registry.bin");

    // Load feature database and registry.
    var db = types.loadFeatures(cli.g_allocator, feat_path, io) catch |err| {
        cli.err("cannot load features: {s} ({})", .{ feat_path, err });
        return 1;
    };
    defer db.deinit();

    var reg = types.loadRegistry(cli.g_allocator, reg_path, io) catch |err| {
        cli.err("cannot load registry: {s} ({})", .{ reg_path, err });
        return 1;
    };
    defer reg.deinit();

    cli.info("library: {d} pages | scales={d} G={d} edges={d} | feat_len={d}", .{
        db.n_pages,
        db.n_scales,
        db.G,
        @as(u32, if (db.has_edges) 1 else 0),
        db.feat_len,
    });

    // Open the video decoder.
    const video_path_z = try toNullTerminated(cli.g_allocator, opts.video);
    defer cli.g_allocator.free(video_path_z);

    var decoder = video.VideoDecoder.open(cli.g_allocator, video_path_z) catch |err| {
        cli.err("cannot open video: {s} ({})", .{ opts.video, err });
        return 1;
    };
    defer decoder.deinit();

    const fw = decoder.getWidth();
    const fh = decoder.getHeight();
    const source_fps = decoder.getFps();
    cli.info("video: {d}x{d} | fps={d:.1}", .{ fw, fh, source_fps });

    // Create the arranger.
    const max_block_pct: f64 = cli.optFloat("max-block-pct", 0.5);
    const hero_min_pct: f64 = cli.optFloat("hero-min-pct", 0.0833);
    var arranger = arrange.Arranger.init(cli.g_allocator, &db, fw, fh, max_block_pct, hero_min_pct);
    defer arranger.deinit();

    // Wire thread count to matcher.
    match.setThreads(cli.ctx().threads);

    // Ensure output directory exists.
    std.Io.Dir.cwd().createDir(io, opts.manifests, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            cli.err("cannot create manifests dir: {s}", .{opts.manifests});
            return 1;
        }
    };

    // Write fps sidecar for the renderer.
    arrange.writeFpsSidecar(opts.manifests, source_fps, io) catch |err| {
        cli.err("cannot write fps sidecar: {}", .{err});
        return 1;
    };

    // Decode and process frames.
    var frame_idx: u32 = 0;
    var timings = arrange.Timings{};
    // Use max_frames as total estimate if set, otherwise 0 (unknown).
    const total_estimate: u32 = if (opts.max_frames > 0) opts.max_frames else 0;
    const start_time = nowNanos();

    while (true) {
        if (opts.max_frames > 0 and frame_idx >= opts.max_frames) break;

        const result = decoder.next() catch |err| {
            cli.err("decode error at frame {d}: {}", .{ frame_idx, err });
            break;
        };

        switch (result) {
            .end_of_stream => break,
            .frame => |bgr_img_val| {
                var bgr_img = bgr_img_val;
                defer bgr_img.deinit();

                // Convert to grayscale for the solver.
                var gray_img = imgops.toGray(&bgr_img) catch |err| {
                    cli.err("toGray failed at frame {d}: {}", .{ frame_idx, err });
                    break;
                };
                defer gray_img.deinit();

                // Process the frame through the arrange pipeline.
                var manifest = arranger.processFrame(
                    gray_img.pixels,
                    bgr_img.pixels,
                    bgr_img.stride,
                    fw,
                    fh,
                    &db,
                    &reg,
                    &timings,
                ) catch |err| {
                    cli.err("processFrame failed at frame {d}: {}", .{ frame_idx, err });
                    break;
                };
                defer manifest.deinit(cli.g_allocator);

                // Write the manifest file.
                arrange.writeManifest(opts.manifests, frame_idx, fw, fh, manifest.items, io) catch |err| {
                    cli.err("writeManifest failed at frame {d}: {}", .{ frame_idx, err });
                    break;
                };

                frame_idx +|= 1;

                // Progress reporting with timing and cache stats.
                const now = nowNanos();
                const elapsed = @as(f64, @floatFromInt(now - start_time)) / 1_000_000_000.0;
                const fps = @as(f64, @floatFromInt(frame_idx)) / @max(elapsed, 0.001);
                const detail = timings.tiles + timings.hits;
                const cache_pct = if (detail > 0) @as(f64, @floatFromInt(timings.hits)) / @as(f64, @floatFromInt(detail)) * 100.0 else 0.0;
                cli.progressFrame("arrange", frame_idx, total_estimate, fps, cache_pct);
            },
        }
    }

    // Arrange summary.
    {
        const end_time = nowNanos();
        const elapsed = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000_000.0;
        const fps = @as(f64, @floatFromInt(frame_idx)) / @max(elapsed, 0.001);
        const detail = timings.tiles + timings.hits;
        const cache_pct = if (detail > 0) @as(f64, @floatFromInt(timings.hits)) / @as(f64, @floatFromInt(detail)) * 100.0 else 0.0;
        var buf: [256]u8 = undefined;
        const summary = std.fmt.bufPrint(&buf, "arrange complete in {d:.2}s | {d:.1} fps | {d} frames | cache {d:.1}% | {d} tiles", .{
            elapsed, fps, frame_idx, cache_pct, detail,
        }) catch "arrange complete";
        cli.progressDone(summary);
    }
    cli.info("wrote {d} manifests to {s}", .{ frame_idx, opts.manifests });
    return 0;
}

/// Run the render subcommand.
fn runRender(opts: types.Options, io: std.Io) !u8 {
    cli.info("badziggle render — starting", .{});

    const manifest_dir = if (opts.manifests.len > 0) opts.manifests else "manifests_greedy";
    const output = if (opts.output.len > 0) opts.output else "output.mov";

    // Resolve library path so registry/features resolve correctly.
    var lib_opts = opts;
    resolveLibraryPath(&lib_opts);
    const registry_path = resolveFilePath(lib_opts.library, opts.registry, "registry.bin");

    cli.info("manifests: {s}", .{manifest_dir});
    cli.info("output: {s}", .{output});

    // Build RenderOptions.
    const render_opts = render.RenderOptions{
        .manifest_dir = manifest_dir,
        .registry_path = registry_path,
        .output = output,
        .width = @intCast(opts.width),
        .height = @intCast(opts.height),
        .fps = 0.0, // auto-detect from fps sidecar
        .max_frames = opts.max_frames,
        .channels = opts.channels,
    };

    // Open the video encoder.
    const output_z = try toNullTerminated(cli.g_allocator, output);
    defer cli.g_allocator.free(output_z);

    const width: u32 = if (opts.width > 0) opts.width else 7680;
    const height: u32 = if (opts.height > 0) opts.height else 4320;
    const channels = if (opts.channels == 3) @as(u32, 3) else @as(u32, 1);

    // Determine codec: try hardware first, fall back to software ProRes.
    const hw_codec = video.probeHwEncoder();
    const use_hw = hw_codec != null and !cli.has("no-hw");

    // Resolve pix_fmt and codec name.
    var pix_fmt_name: [*:0]const u8 = "gray";
    var codec_name: ?[*:0]const u8 = null;

    if (channels == 3) {
        if (use_hw) {
            if (hw_codec) |hw| {
                codec_name = hw;
                pix_fmt_name = "yuv420p";
                cli.info("hw encoder: {s}", .{std.mem.span(hw)});
            }
        } else {
            codec_name = "prores_ks";
            pix_fmt_name = "yuv422p10le";
            cli.info("sw encoder: prores_ks", .{});
        }
    }

    const src_fps = render.readFpsFile(cli.g_allocator, manifest_dir, io);
    const encoder_fps = if (src_fps > 0.0) src_fps else 30.0;

    var encoder = video.VideoEncoder.open(
        cli.g_allocator,
        output_z,
        width,
        height,
        encoder_fps,
        pix_fmt_name,
        codec_name,
    ) catch |err| {
        cli.err("cannot open encoder: {}", .{err});
        return 1;
    };
    defer encoder.deinit();

    // Create an encoder reference for the pipeline.
    const EncoderContext = struct {
        enc: *video.VideoEncoder,
    };
    var ctx = EncoderContext{ .enc = &encoder };

    var enc_ref = render.EncodePipeline.VideoEncoderRef{
        .write_fn = struct {
            fn write(c: *anyopaque, pixels: []const u8, w: u32, h: u32, ch: u32) void {
                const ec: *EncoderContext = @ptrCast(@alignCast(c));
                var img = types.Img{
                    .w = w,
                    .h = h,
                    .stride = w * ch,
                    .channels = ch,
                    .pixels = @constCast(pixels),
                    .allocator = undefined,
                };
                ec.enc.write(&img) catch |err| {
                    cli.err("encode write error: {}", .{err});
                };
            }
        }.write,
        .ctx = @ptrCast(&ctx),
    };

    // Load the registry for source image lookup.
    var reg = types.loadRegistry(cli.g_allocator, registry_path, io) catch |err| {
        cli.err("cannot load registry: {s} ({})", .{ registry_path, err });
        return 1;
    };
    defer reg.deinit();

    // Create source renderer for loading library images.
    var source_renderer = render.ImageSourceRenderer.init(&reg, cli.g_allocator);
    var source_ref = source_renderer.toSourceRenderer();

    // Run the render pipeline with source renderer.
    _ = render.render(cli.g_allocator, render_opts, &source_ref, &enc_ref, io) catch |err| {
        cli.err("render failed: {}", .{err});
        return 1;
    };

    cli.progressDone("render complete");
    return 0;
}

/// Run the build subcommand.
fn runBuild(opts: types.Options, sources_dir: []const u8, io: std.Io) !u8 {
    cli.info("badziggle build — starting", .{});

    if (sources_dir.len == 0) {
        cli.die("sources_dir is required for build", .{});
    }

    const G = opts.bits;
    if (G == 0 or G > 8) {
        cli.die("--bits must be 1..8", .{});
    }
    const has_edges = !opts.no_edges;
    const color = opts.color;

    // Use provided scales or defaults.
    const scales = if (opts.scales.len > 0) opts.scales else &[_]u32{ 32, 64, 128 };

    // Compute feat_len.
    var feat_len: u32 = 0;
    for (scales) |N| {
        feat_len += N * N; // gray
        if (has_edges) feat_len += N * N; // edge
        if (color) feat_len += N * N * 3; // color BGR
    }

    cli.info("sources_dir: {s}", .{sources_dir});
    cli.info("scales: {d} levels | G={d} | edges={d} | color={d} | feat_len={d}", .{
        scales.len,
        G,
        @as(u32, if (has_edges) 1 else 0),
        @as(u32, if (color) 1 else 0),
        feat_len,
    });

    // Scan the sources directory for image files.
    var dir = std.Io.Dir.cwd().openDir(io, sources_dir, .{ .iterate = true }) catch |err| {
        cli.err("cannot open sources dir: {s} ({})", .{ sources_dir, err });
        return 1;
    };
    defer dir.close(io);

    // Collect all image file paths (PNG, JPEG, TIFF, BMP, etc.).
    var file_paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (file_paths.items) |p| cli.g_allocator.free(p);
        file_paths.deinit(cli.g_allocator);
    }

    // Also track the source file name for the registry.
    var source_names: std.ArrayList([]const u8) = .empty;
    defer {
        for (source_names.items) |n| cli.g_allocator.free(n);
        source_names.deinit(cli.g_allocator);
    }

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        // Check for image extensions.
        const ext = if (name.len >= 5) name[name.len - 4 ..] else "";
        const is_image = std.ascii.eqlIgnoreCase(ext, ".png") or
            std.ascii.eqlIgnoreCase(ext, ".jpg") or
            std.ascii.eqlIgnoreCase(ext, ".jpeg") or
            std.ascii.eqlIgnoreCase(ext, ".tif") or
            std.ascii.eqlIgnoreCase(ext, ".tiff") or
            std.ascii.eqlIgnoreCase(ext, ".bmp");
        const is_pdf = std.ascii.eqlIgnoreCase(ext, ".pdf");

        if (is_image) {
            const full_path = std.fmt.allocPrint(cli.g_allocator, "{s}/{s}", .{ sources_dir, name }) catch continue;
            try file_paths.append(cli.g_allocator, full_path);

            // Store the original name (without extension) for the registry.
            const base = std.fs.path.stem(name);
            const name_copy = cli.g_allocator.dupe(u8, base) catch continue;
            try source_names.append(cli.g_allocator, name_copy);
        } else if (is_pdf) {
            cli.warn("skipping PDF (mupdf not available): {s}", .{name});
        }
    }

    if (file_paths.items.len == 0) {
        cli.err("no image files found in {s}", .{sources_dir});
        return 1;
    }

    cli.info("found {d} images", .{file_paths.items.len});

    // Extract features from each image.
    const n_pages: u32 = @intCast(file_paths.items.len);
    const feat_data_len = @as(usize, n_pages) * feat_len;
    var feat_data = try cli.g_allocator.alloc(u8, feat_data_len);
    defer cli.g_allocator.free(feat_data);
    @memset(feat_data, 0);

    // Build registry entries.
    var reg_entries = try cli.g_allocator.alloc(types.RegEntry, n_pages);
    defer {
        for (reg_entries) |e| cli.g_allocator.free(e.pdf_path);
        cli.g_allocator.free(reg_entries);
    }

    var pages_done: u32 = 0;
    for (file_paths.items, 0..) |fp, i| {
        const fp_z = try toNullTerminated(cli.g_allocator, fp);
        defer cli.g_allocator.free(fp_z);

        var img = video.imageLoad(cli.g_allocator, fp_z) catch |err| {
            cli.warn("skip {s}: {}", .{ fp, err });
            continue;
        };
        defer img.deinit();

        // Extract multi-resolution features.
        const offset = @as(usize, i) * feat_len;
        imgops.computeFeatureMultires(
            &img,
            scales,
            G,
            has_edges,
            color,
            feat_data[offset..][0..feat_len],
        ) catch |err| {
            cli.warn("feature extraction failed for {s}: {}", .{ fp, err });
            continue;
        };

        // Registry entry: page_idx = i, pdf_path = source file name.
        reg_entries[i] = .{
            .page_idx = @intCast(i),
            .pdf_path = try cli.g_allocator.dupe(u8, source_names.items[i]),
        };

        pages_done +|= 1;
        cli.progressFrame("build", pages_done, n_pages, 0, 0);
    }

    if (pages_done == 0) {
        cli.err("no images were successfully processed", .{});
        return 1;
    }

    // Write features.bin.
    const feat_out = if (opts.output.len > 0) opts.output else "features.bin";
    writeFeaturesBin(feat_out, pages_done, feat_len, G, scales, has_edges, color, feat_data[0..@as(usize, pages_done) * feat_len], io) catch |err| {
        cli.err("cannot write features: {s} ({})", .{ feat_out, err });
        return 1;
    };
    cli.info("wrote features: {s} ({d} pages, {d} bytes/page)", .{ feat_out, pages_done, feat_len });

    // Write registry.bin.
    const reg_out = "registry.bin";
    writeRegistryBin(reg_out, reg_entries[0..pages_done], io) catch |err| {
        cli.err("cannot write registry: {s} ({})", .{ reg_out, err });
        return 1;
    };
    cli.info("wrote registry: {s} ({d} entries)", .{ reg_out, pages_done });

    cli.progressDone("build complete");
    return 0;
}

/// Detect source video dimensions and fps to auto-set output width/height.
fn autoDetectSource(video_path: []const u8, opts: *types.Options) void {
    _ = video_path;
    if (opts.width == 0) opts.width = 1920;
    if (opts.height == 0) opts.height = 1080;
}

/// Resolve a file path: if `path` is an absolute path, return it directly;
/// otherwise join `base/path` and return that.
fn resolveFilePath(base: []const u8, path: []const u8, fallback: []const u8) []const u8 {
    const p = if (path.len > 0) path else fallback;
    if (p.len > 0 and p[0] == '/') return p; // absolute
    if (base.len == 0) return p;
    return std.fmt.allocPrint(cli.g_allocator, "{s}/{s}", .{ base, p }) catch p;
}

/// Convert a regular string slice to a null-terminated string.
fn toNullTerminated(allocator: std.mem.Allocator, s: []const u8) ![:0]const u8 {
    return try allocator.dupeZ(u8, s);
}

/// Write features.bin in the binary format expected by the arrange pipeline.
fn writeFeaturesBin(
    path: []const u8,
    n_pages: u32,
    feat_len: u32,
    G: u32,
    scales: []const u32,
    has_edges: bool,
    color: bool,
    data: []const u8,
    io: std.Io,
) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var write_buf: [4096]u8 = undefined;
    var fw = file.writer(io, &write_buf);

    // Header.
    try fw.interface.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(u32, n_pages)));
    try fw.interface.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(u32, feat_len)));
    try fw.interface.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(u32, G)));
    try fw.interface.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(u32, @intCast(scales.len))));

    // Scale array.
    for (scales) |s| {
        try fw.interface.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(u32, s)));
    }

    // has_edges.
    try fw.interface.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(u32, if (has_edges) 1 else 0)));

    // channels field (present when feat_len implies color).
    if (color) {
        try fw.interface.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(u32, 3)));
    }

    // Feature data.
    try fw.interface.writeAll(data);

    try fw.interface.flush();
}

/// Write registry.bin in the binary format expected by the render pipeline.
fn writeRegistryBin(path: []const u8, entries: []const types.RegEntry, io: std.Io) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var write_buf: [4096]u8 = undefined;
    var fw = file.writer(io, &write_buf);

    try fw.interface.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(u32, @intCast(entries.len))));

    for (entries) |entry| {
        try fw.interface.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(i32, entry.page_idx)));
        try fw.interface.writeAll(std.mem.asBytes(&std.mem.nativeToLittle(u32, @intCast(entry.pdf_path.len))));
        try fw.interface.writeAll(entry.pdf_path);
    }

    try fw.interface.flush();
}

/// Convert slice of null-terminated strings to regular string slice.
fn cStrVectorToSlice(allocator: std.mem.Allocator, vec: []const [*:0]const u8) ![][]const u8 {
    var result = try allocator.alloc([]const u8, vec.len);
    for (vec, 0..) |ptr, i| {
        result[i] = std.mem.span(ptr);
    }
    return result;
}

pub fn main(init: std.process.Init) u8 {
    const allocator = std.heap.page_allocator;
    const io = init.io;
    cli.g_allocator = allocator;
    cli.init(allocator);

    const raw_args = init.minimal.args.vector;
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
        return runArrange(&opts, io) catch 1;
    }

    if (std.mem.eql(u8, cmd, "render")) {
        if (cli.has("help")) {
            printRenderHelp();
            return 0;
        }
        const opts = cli.buildOptions();
        return runRender(opts, io) catch 1;
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

        return runBuild(opts, sources_dir, io) catch 1;
    }

    // Shorthand: <input> <output> [options] — auto-detect as arrange+render pipeline
    // If cmd is not a known subcommand and doesn't start with '-', treat first two
    // positional args as input/output (matches C badapplestein behavior).
    if (cmd.len > 0 and cmd[0] != '-') {
        // Find the next positional arg after cmd (skip any --flags and their values)
        var output_arg: []const u8 = "";
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (arg.len >= 2 and arg[0] == '-') {
                // Skip flag and its value if opt_needs_value
                if (arg.len >= 3 and arg[1] == '-') {
                    // --key or --key=val — skip value for known options that need one
                    const key = arg[2..];
                    if (std.mem.eql(u8, key, "library") or std.mem.eql(u8, key, "features") or
                        std.mem.eql(u8, key, "registry") or std.mem.eql(u8, key, "manifests") or
                        std.mem.eql(u8, key, "preset") or std.mem.eql(u8, key, "width") or
                        std.mem.eql(u8, key, "height") or std.mem.eql(u8, key, "fps") or
                        std.mem.eql(u8, key, "codec") or std.mem.eql(u8, key, "max-frames") or
                        std.mem.eql(u8, key, "threads") or std.mem.eql(u8, key, "max-block-pct") or
                        std.mem.eql(u8, key, "hero-min-pct") or std.mem.eql(u8, key, "out"))
                    {
                        // Check for --key=value form (no separate value arg needed)
                        if (std.mem.indexOfScalar(u8, key, '=') == null) i += 1;
                    }
                }
                continue;
            }
            // Found a positional arg — this is the output
            output_arg = arg;
            break;
        }

        if (output_arg.len > 0) {
            cli.info("badziggle shorthand encode: {s} -> {s}", .{ cmd, output_arg });

            var opts = cli.buildOptions();
            opts.video = cmd;
            opts.output = output_arg;
            resolveLibraryPath(&opts);

            // Create a temp manifests directory in the output's parent.
            const output_dir = std.fs.path.dirname(output_arg) orelse ".";
            const manifests_dir = std.fmt.allocPrint(cli.g_allocator, "{s}/.badziggle-manifests", .{output_dir}) catch {
                cli.err("out of memory", .{});
                return 1;
            };
            defer cli.g_allocator.free(manifests_dir);

            // Stage 1: Arrange.
            opts.manifests = manifests_dir;
            cli.info("arranging...", .{});
            const arrange_rc = runArrange(&opts, io) catch 1;
            if (arrange_rc != 0) {
                cli.err("arrange stage failed", .{});
                return 1;
            }

            // Stage 2: Render.
            cli.info("rendering...", .{});
            const render_rc = runRender(opts, io) catch 1;
            if (render_rc != 0) {
                cli.err("render stage failed", .{});
                return 1;
            }

            // Clean up temp manifests unless --keep-manifests.
            if (!cli.has("keep-manifests")) {
                std.Io.Dir.cwd().deleteTree(io, manifests_dir) catch {};
            } else {
                cli.info("keeping manifests: {s}", .{manifests_dir});
            }

            return 0;
        }
    }

    cli.err("unknown command '{s}'", .{cmd});
    cli.info("Run 'badziggle help' for usage.", .{});
    return 1;
}
