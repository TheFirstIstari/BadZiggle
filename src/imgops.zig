/// imgops — pure-Zig image operations (no OpenCV).
/// Replaces the C imgops module from BadApplestein with idiomatic Zig.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Img = @import("types.zig").Img;

/// Rec.601 luma coefficients (BGR order, matching OpenCV convention).
const luma_b: u32 = 29;
const luma_g: u32 = 150;
const luma_r: u32 = 77;

/// Convert an RGB/BGR Img to grayscale using Rec.601 luma.
/// If src is already grayscale (channels==1), returns a copy.
/// Caller owns the returned Img and must call deinit() on it.
pub fn toGray(src: *const Img) !Img {
    if (src.channels == 1) {
        const dst = try Img.init(src.allocator, src.w, src.h, 1);
        @memcpy(dst.pixels, src.pixels[0 .. src.w * src.h]);
        return dst;
    }

    const dst = try Img.init(src.allocator, src.w, src.h, 1);
    for (0..src.h) |y| {
        const src_row_offset = y * src.stride;
        const dst_row_offset = y * @as(usize, dst.w);
        for (0..src.w) |x| {
            const p = src.pixels[src_row_offset + x * 3 ..][0..3];
            const v = (luma_b * p[0] + luma_g * p[1] + luma_r * p[2] + 128) >> 8;
            dst.pixels[dst_row_offset + x] = @intCast(@min(v, 255));
        }
    }
    return dst;
}

/// Area-resample src into dst of size (nw, nh).
/// Uses box/area average per destination pixel (INTER_AREA-like).
/// Caller owns the returned Img and must call deinit() on it.
pub fn resizeArea(src: *const Img, nw: u32, nh: u32) !Img {
    const ch = src.channels;
    const sw = src.w;
    const sh = src.h;

    if (sw == 0 or sh == 0 or nw == 0 or nh == 0) {
        return Img{
            .w = 0,
            .h = 0,
            .stride = 0,
            .channels = 0,
            .pixels = &.{},
            .allocator = src.allocator,
        };
    }

    var dst = try Img.init(src.allocator, nw, nh, ch);

    // Fast path: exact integer upscale.
    // For integer upscale factors, area resampling equals nearest-neighbor
    // replication (each dest pixel covers exactly k source pixels of the
    // same value). This is the common case for small tiles (e.g. 8x8->64x64).
    if (nw % sw == 0 and nh % sh == 0 and nw != sw) {
        const ux = nw / sw;
        const uy = nh / sh;
        if (ux > 0 and uy > 0) {
            for (0..nh) |y| {
                const sy = y / uy;
                const src_row = src.pixels[sy * src.stride ..];
                const dst_row = dst.pixels[y * dst.stride ..];
                for (0..nw) |x| {
                    const sx = x / ux;
                    const sp = src_row[sx * ch ..][0..ch];
                    const dp = dst_row[x * ch ..][0..ch];
                    @memcpy(dp, sp);
                }
            }
            return dst;
        }
    }

    // General area resampling.
    for (0..nh) |y| {
        const sy0: u32 = @intCast(@as(u64, y) * sh / nh);
        var sy1: u32 = @intCast(@as(u64, y + 1) * sh / nh);
        if (sy1 > sh) sy1 = sh;
        if (sy0 >= sy1) sy1 = sy0 + 1;

        for (0..nw) |x| {
            const sx0: u32 = @intCast(@as(u64, x) * sw / nw);
            var sx1: u32 = @intCast(@as(u64, x + 1) * sw / nw);
            if (sx1 > sw) sx1 = sw;
            if (sx0 >= sx1) sx1 = sx0 + 1;

            const area: u32 = (sy1 - sy0) * (sx1 - sx0);
            for (0..ch) |c| {
                var sum: u64 = 0;
                var cy = sy0;
                while (cy < sy1) : (cy += 1) {
                    var cx = sx0;
                    while (cx < sx1) : (cx += 1) {
                        sum += src.pixels[cy * src.stride + cx * ch + c];
                    }
                }
                const v: u32 = @intCast(sum / area);
                dst.pixels[y * dst.stride + x * ch + c] = @intCast(@min(v, 255));
            }
        }
    }

    return dst;
}

/// Threshold a grayscale buffer in place: out = (v > thr) ? maxval : 0.
pub fn thresholdU8(buf: []u8, thr: u8, maxval: u8) void {
    for (buf) |*b| {
        b.* = if (b.* > thr) maxval else 0;
    }
}

/// Compute an integral (sum) image of a grayscale buffer.
/// Returns a (h+1)*(w+1) i64 buffer. out[y*(w+1)+x] = sum over [0..y-1,0..x-1].
/// Uses i64 to avoid overflow for frames above ~4K resolution.
/// Caller owns the returned slice and must free it with allocator.free().
pub fn integral(gray: []const u8, w: u32, h: u32, allocator: Allocator) ![]i64 {
    const stride = w + 1;
    const total = @as(usize, stride) * (h + 1);
    const I = try allocator.alloc(i64, total);
    // Zero-initialize.
    @memset(I, 0);

    for (0..h) |y| {
        var rowsum: i64 = 0;
        for (0..w) |x| {
            rowsum += gray[y * w + x];
            I[(y + 1) * stride + (x + 1)] = I[y * stride + (x + 1)] + rowsum;
        }
        I[(y + 1) * stride] = 0;
    }

    return I;
}

/// Compute Sobel edge magnitude of a grayscale buffer.
/// gray: input grayscale buffer (w*h bytes, row-major).
/// out: pre-allocated output buffer (w*h bytes).
/// Border pixels are filled from nearest interior pixel.
pub fn sobelMagnitude(gray: []const u8, w: u32, h: u32, out: []u8) void {
    // Interior pixels.
    for (1..h - 1) |y| {
        const row_top = gray[(y - 1) * w ..];
        const row_mid = gray[y * w ..];
        const row_bot = gray[(y + 1) * w ..];
        const row_out = out[y * w ..];

        for (1..w - 1) |x| {
            const tl: i32 = row_top[x - 1];
            const tc: i32 = row_top[x];
            const tr: i32 = row_top[x + 1];
            const ml: i32 = row_mid[x - 1];
            const mr: i32 = row_mid[x + 1];
            const bl: i32 = row_bot[x - 1];
            const bc: i32 = row_bot[x];
            const br: i32 = row_bot[x + 1];

            const gx = -tl + tr - 2 * ml + 2 * mr - bl + br;
            const gy = -tl - 2 * tc - tr + bl + 2 * bc + br;

            const ax: u32 = @intCast(@abs(gx));
            const ay: u32 = @intCast(@abs(gy));
            const mag: u32 = if (ax >= ay) ax + ay / 2 else ay + ax / 2;
            row_out[x] = @intCast(@min(mag, 255));
        }
    }

    // Fill border pixels by copying from nearest interior.
    if (h > 1) {
        for (0..w) |x| {
            out[x] = out[w + x];
        }
    }
    if (h > 2) {
        const last = (h - 1) * w;
        const prev = (h - 2) * w;
        for (0..w) |x| {
            out[last + x] = out[prev + x];
        }
    }
    for (0..h) |y| {
        const row = out[y * w ..];
        if (w > 1) row[0] = row[1];
        if (w > 2) row[w - 1] = row[w - 2];
    }
}

/// Compute a single-scale feature vector for a tile crop.
///   crop: source Img (3-channel BGR or 1-channel gray)
///   N: grid size
///   G: bits per cell (1..8)
///   color: if true, extract 3-channel (BGR) features; else 1-channel (gray)
///   out: caller-allocated buffer of N*N*(color ? 3 : 1) bytes
///
/// The crop is area-resampled to NxN, then each cell is quantized:
///   v_quant = round(v/255 * (2^G - 1))   (G==8 => keep raw 0..255)
pub fn computeFeature(crop: *const Img, N: u32, G: u32, color: bool, out: []u8) !void {
    const ch: u32 = if (color) 3 else 1;

    // Prepare working image in the requested channel count.
    var work_img: ?Img = null;
    defer if (work_img) |*w| w.deinit();

    if (!color and crop.channels == 3) {
        // Grayscale mode with BGR input: convert first.
        work_img = try toGray(crop);
    } else if (color and crop.channels == 1) {
        // Color mode with gray input: replicate to 3 channels.
        var work = try Img.init(crop.allocator, crop.w, crop.h, 3);
        for (0..@as(usize, crop.w) * crop.h) |i| {
            const v = crop.pixels[i];
            work.pixels[i * 3 + 0] = v;
            work.pixels[i * 3 + 1] = v;
            work.pixels[i * 3 + 2] = v;
        }
        work_img = work;
    } else {
        // Channel count matches mode: copy as-is.
        const work = try Img.init(crop.allocator, crop.w, crop.h, crop.channels);
        @memcpy(work.pixels, crop.pixels[0 .. crop.stride * crop.h]);
        work_img = work;
    }

    // Resize to NxN and extract features.
    if (work_img) |*w| {
        var rs = try resizeArea(w, N, N);
        defer rs.deinit();

        const maxv: u32 = (@as(u32, 1) << @intCast(G)) - 1;
        var idx: usize = 0;
        for (0..ch) |c| {
            for (0..N) |y| {
                for (0..N) |x| {
                    const v: u32 = rs.pixels[y * rs.stride + x * ch + c];
                    const q: u32 = if (G >= 8) v else (v * maxv + 127) / 255;
                    out[idx] = @intCast(@min(q, maxv));
                    idx += 1;
                }
            }
        }
    }
}

/// Compute output buffer size for computeFeatureMultires.
pub fn featureMultiresOutputSize(scales: []const u32, has_edges: bool, color: bool) usize {
    var total: usize = 0;
    for (scales) |N| {
        if (color) {
            // gray(N*N) + color(3*N*N) = 4*N*N, plus edge(N*N) if has_edges
            total += @as(usize, N) * N * 4;
            if (has_edges) total += @as(usize, N) * N;
        } else {
            // gray(N*N), plus edge(N*N) if has_edges
            total += @as(usize, N) * N;
            if (has_edges) total += @as(usize, N) * N;
        }
    }
    return total;
}

/// Compute a multi-resolution feature vector with optional edge and color.
///   crop: source Img (3-channel BGR or 1-channel gray)
///   scales: slice of grid sizes (e.g. .{ 32, 64, 128 })
///   G: bits per cell (1..8)
///   has_edges: include Sobel edge magnitude features
///   color: include BGR color features
///   out: caller-allocated buffer of featureMultiresOutputSize() bytes
///
/// For each scale level, computes:
///   - Grayscale feature: NxN cells, area-resampled and quantized
///   - Edge feature (if has_edges): NxN Sobel magnitude cells, quantized
///   - Color feature (if color): 3xNxN BGR cells, area-resampled and quantized
///
/// Output layout:
///   color=false: [gray_s0][edge_s0?][gray_s1][edge_s1?]...
///   color=true:  [gray_s0][edge_s0?][color_s0][gray_s1][edge_s1?][color_s1]...
pub fn computeFeatureMultires(
    crop: *const Img,
    scales: []const u32,
    G: u32,
    has_edges: bool,
    color: bool,
    out: []u8,
) !void {
    // Zero the output buffer.
    const total = featureMultiresOutputSize(scales, has_edges, color);
    @memset(out[0..total], 0);

    var idx: usize = 0;

    // Find max scale for buffer allocation.
    var maxN: u32 = 0;
    for (scales) |s| {
        if (s > maxN) maxN = s;
    }

    // Prepare grayscale working data.
    // If we allocate a new grayscale image, track it for cleanup.
    var gray_owned: ?Img = null;
    defer if (gray_owned) |*g| g.deinit();

    if (!color and crop.channels == 3) {
        gray_owned = try toGray(crop);
    }

    // Prepare color working data (if needed).
    var color_owned: ?Img = null;
    defer if (color_owned) |*w| w.deinit();

    if (color and crop.channels == 1) {
        var work = try Img.init(crop.allocator, crop.w, crop.h, 3);
        for (0..@as(usize, crop.w) * crop.h) |i| {
            const v = crop.pixels[i];
            work.pixels[i * 3 + 0] = v;
            work.pixels[i * 3 + 1] = v;
            work.pixels[i * 3 + 2] = v;
        }
        color_owned = work;
    }

    // Pre-allocate working buffers for the largest scale.
    var gray_buf = try crop.allocator.alloc(u8, maxN * maxN);
    defer crop.allocator.free(gray_buf);

    var edge_buf: ?[]u8 = null;
    defer if (edge_buf) |eb| crop.allocator.free(eb);
    if (has_edges) {
        edge_buf = try crop.allocator.alloc(u8, maxN * maxN);
    }

    for (scales) |N| {
        if (color) {
            // --- Color mode: single BGR resize, derive gray + edge + color. ---
            // Determine which Img to resize.
            var resize_src: Img = if (color_owned) |cw| cw else crop.*;
            var rs_color = try resizeArea(&resize_src, N, N);
            defer rs_color.deinit();

            const maxv: u32 = (@as(u32, 1) << @intCast(G)) - 1;

            // Derive grayscale from resized BGR (Rec.601 luma).
            for (0..N) |y| {
                for (0..N) |x| {
                    const p = rs_color.pixels[y * rs_color.stride + x * 3 ..][0..3];
                    const v: u32 = (luma_b * p[0] + luma_g * p[1] + luma_r * p[2] + 128) >> 8;
                    gray_buf[y * N + x] = @intCast(@min(v, 255));
                }
            }

            // Grayscale feature.
            for (0..N) |y| {
                for (0..N) |x| {
                    const v: u32 = gray_buf[y * N + x];
                    const q: u32 = if (G >= 8) v else (v * maxv + 127) / 255;
                    out[idx] = @intCast(@min(q, maxv));
                    idx += 1;
                }
            }

            // Edge feature.
            if (has_edges) {
                sobelMagnitude(gray_buf[0 .. N * N], N, N, edge_buf.?);
                for (0..N) |y| {
                    for (0..N) |x| {
                        const v: u32 = edge_buf.?[y * N + x];
                        const q: u32 = if (G >= 8) v else (v * maxv + 127) / 255;
                        out[idx] = @intCast(@min(q, maxv));
                        idx += 1;
                    }
                }
            }

            // Color feature: BGR channels, quantized.
            for (0..3) |c| {
                for (0..N) |y| {
                    for (0..N) |x| {
                        const v: u32 = rs_color.pixels[y * rs_color.stride + x * 3 + c];
                        const q: u32 = if (G >= 8) v else (v * maxv + 127) / 255;
                        out[idx] = @intCast(@min(q, maxv));
                        idx += 1;
                    }
                }
            }
        } else {
            // --- Grayscale-only mode. ---
            // Build a grayscale Img to pass to resizeArea.
            var gray_src: Img = if (gray_owned) |g| g else Img{
                .w = crop.w,
                .h = crop.h,
                .stride = crop.w,
                .channels = 1,
                .pixels = crop.pixels,
                .allocator = crop.allocator,
            };

            var rs = try resizeArea(&gray_src, N, N);
            defer rs.deinit();

            const maxv: u32 = (@as(u32, 1) << @intCast(G)) - 1;

            // Grayscale feature.
            for (0..N) |y| {
                for (0..N) |x| {
                    const v: u32 = rs.pixels[y * rs.stride + x];
                    const q: u32 = if (G >= 8) v else (v * maxv + 127) / 255;
                    out[idx] = @intCast(@min(q, maxv));
                    idx += 1;
                }
            }

            // Edge feature.
            if (has_edges) {
                sobelMagnitude(rs.pixels[0 .. N * N], N, N, edge_buf.?);
                for (0..N) |y| {
                    for (0..N) |x| {
                        const v: u32 = edge_buf.?[y * N + x];
                        const q: u32 = if (G >= 8) v else (v * maxv + 127) / 255;
                        out[idx] = @intCast(@min(q, maxv));
                        idx += 1;
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "toGray: copies grayscale unchanged" {
    const allocator = std.testing.allocator;
    var src = try Img.init(allocator, 4, 4, 1);
    defer src.deinit();
    for (src.pixels, 0..) |*p, i| p.* = @intCast(i % 256);

    var dst = try toGray(&src);
    defer dst.deinit();

    try std.testing.expectEqual(@as(u32, 1), dst.channels);
    try std.testing.expectEqual(src.w, dst.w);
    try std.testing.expectEqual(src.h, dst.h);
    try std.testing.expectEqualSlices(u8, src.pixels[0 .. src.w * src.h], dst.pixels[0 .. dst.w * dst.h]);
}

test "toGray: converts BGR to grayscale" {
    const allocator = std.testing.allocator;
    var src = try Img.init(allocator, 2, 1, 3);
    defer src.deinit();
    // Pixel 0: pure blue (B=255, G=0, R=0) -> luma = 29*255/255 = 29
    src.pixels[0] = 255;
    src.pixels[1] = 0;
    src.pixels[2] = 0;
    // Pixel 1: pure green (B=0, G=255, R=0) -> luma = (150*255+128)>>8 = 149
    src.pixels[3] = 0;
    src.pixels[4] = 255;
    src.pixels[5] = 0;

    var dst = try toGray(&src);
    defer dst.deinit();

    try std.testing.expectEqual(@as(u32, 1), dst.channels);
    try std.testing.expectEqual(@as(u8, 29), dst.pixels[0]);
    try std.testing.expectEqual(@as(u8, 149), dst.pixels[1]);
}

test "thresholdU8" {
    var buf = [_]u8{ 0, 100, 128, 200, 255 };
    thresholdU8(&buf, 128, 255);
    // thresholdU8 uses strict >: 128 > 128 is false
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 255, 255 }, &buf);
}

test "integral: small image" {
    const allocator = std.testing.allocator;
    // 2x2 grayscale image:
    //   1  2
    //   3  4
    const gray = [_]u8{ 1, 2, 3, 4 };
    const I = try integral(&gray, 2, 2, allocator);
    defer allocator.free(I);
    // Integral image (3x3, stride=3):
    //   0  0  0
    //   0  1  3
    //   0  4 10
    try std.testing.expectEqual(@as(i64, 0), I[0]);
    try std.testing.expectEqual(@as(i64, 1), I[4]); // I[1][1]
    try std.testing.expectEqual(@as(i64, 3), I[5]); // I[1][2]
    try std.testing.expectEqual(@as(i64, 4), I[7]); // I[2][1]
    try std.testing.expectEqual(@as(i64, 10), I[8]); // I[2][2]
}

test "sobelMagnitude: flat image produces zeros" {
    var gray: [9]u8 = .{ 128, 128, 128, 128, 128, 128, 128, 128, 128 };
    var out: [9]u8 = undefined;
    sobelMagnitude(&gray, 3, 3, &out);
    // Interior pixel should be 0 (no gradient).
    try std.testing.expectEqual(@as(u8, 0), out[4]);
}

test "resizeArea: integer upscale" {
    const allocator = std.testing.allocator;
    var src = try Img.init(allocator, 2, 2, 1);
    defer src.deinit();
    src.pixels[0] = 10;
    src.pixels[1] = 20;
    src.pixels[2] = 30;
    src.pixels[3] = 40;

    var dst = try resizeArea(&src, 4, 4);
    defer dst.deinit();

    try std.testing.expectEqual(@as(u32, 4), dst.w);
    try std.testing.expectEqual(@as(u32, 4), dst.h);
    // Top-left quadrant should all be 10.
    try std.testing.expectEqual(@as(u8, 10), dst.pixels[0]);
    try std.testing.expectEqual(@as(u8, 10), dst.pixels[1]);
    try std.testing.expectEqual(@as(u8, 10), dst.pixels[4]);
    try std.testing.expectEqual(@as(u8, 10), dst.pixels[5]);
    // Bottom-right quadrant should all be 40.
    try std.testing.expectEqual(@as(u8, 40), dst.pixels[15]);
}

test "featureMultiresOutputSize" {
    const scales = [_]u32{ 8, 16 };
    // Grayscale, no edges: 8*8 + 16*16 = 64 + 256 = 320
    try std.testing.expectEqual(@as(usize, 320), featureMultiresOutputSize(&scales, false, false));
    // Grayscale, with edges: (8*8 + 8*8) + (16*16 + 16*16) = 128 + 512 = 640
    try std.testing.expectEqual(@as(usize, 640), featureMultiresOutputSize(&scales, true, false));
    // Color, no edges: (8*8*4) + (16*16*4) = 256 + 1024 = 1280
    try std.testing.expectEqual(@as(usize, 1280), featureMultiresOutputSize(&scales, false, true));
    // Color, with edges: (8*8*5) + (16*16*5) = 320 + 1280 = 1600
    try std.testing.expectEqual(@as(usize, 1600), featureMultiresOutputSize(&scales, true, true));
}
