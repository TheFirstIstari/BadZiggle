//! video.zig — FFmpeg libav* decode/encode (pure Zig, no OpenCV).
//!
//! Decode: open a file, pull frames as BGR24 Img (channels==3), one per call.
//! Encode: feed BGR24/GRAY8 frames, mux to a file (e.g. prores/mov).

const std = @import("std");
const c = @cImport({
    @cInclude("libavformat/avformat.h");
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libswscale/swscale.h");
    @cInclude("libavutil/imgutils.h");
    @cInclude("libavutil/opt.h");
});

const types = @import("types.zig");
const Img = types.Img;

// ---------------------------------------------------------------------------
// FFmpeg constants not reliably exposed by @cImport (macro-defined)
// ---------------------------------------------------------------------------

const AVFMT_NOFILE = 0x0001;
const AVFMT_GLOBALHEADER = 0x00100000;
const AV_CODEC_FLAG_GLOBAL_HEADER = 1 << 22;
const FF_THREAD_SLICE = 0x0001;
const AVIO_FLAG_WRITE = 2;
const SWS_BILINEAR: c_int = 2;

/// FFmpeg error-tag helper (mirrors FFERRTAG macro).
fn fferrtag(a: u8, b: u8, c_val: u8, d: u8) c_int {
    return -@as(c_int, @intCast(
        @as(u32, a) | (@as(u32, b) << 8) | (@as(u32, c_val) << 16) | (@as(u32, d) << 24),
    ));
}

const AVERROR_EOF = fferrtag('E', 'O', 'F', ' ');
// AVERROR(EAGAIN) = -(EAGAIN). EAGAIN is 35 on macOS, 11 on Linux.
const builtin = @import("builtin");
const AVERROR_EAGAIN: c_int = if (builtin.os.tag == .macos) -35 else -11;

// ---------------------------------------------------------------------------
// Error set
// ---------------------------------------------------------------------------

pub const VideoError = error{
    OutOfMemory,
    FormatOpenFailed,
    StreamInfoFailed,
    NoVideoStream,
    CodecNotFound,
    CodecAllocFailed,
    CodecParamsFailed,
    CodecOpenFailed,
    SwsAllocFailed,
    FrameAllocFailed,
    PacketAllocFailed,
    FrameBufferFailed,
    OutputFormatNotFound,
    CodecEncoderNotFound,
    StreamCreateFailed,
    FormatOpenWriteFailed,
    FormatHeaderFailed,
    EncodeSendFailed,
    FormatWriteFailed,
};

// ---------------------------------------------------------------------------
// Next-frame result
// ---------------------------------------------------------------------------

pub const NextResult = union(enum) {
    frame: Img,
    end_of_stream,
};

// ---------------------------------------------------------------------------
// Network initialisation (once)
// ---------------------------------------------------------------------------

var network_inited: bool = false;

fn ensureNetworkInit() void {
    if (!network_inited) {
        _ = c.avformat_network_init();
        network_inited = true;
    }
}

// =========================================================================
//  Frame pool — pre-allocated Img slots to avoid per-frame malloc
//  in the decode hot loop. Pool frames use a pool allocator whose
//  free() is a no-op, so the caller's Img.deinit() preserves pool buffers.
// =========================================================================

fn poolAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const allocator: *std.mem.Allocator = @ptrCast(@alignCast(ctx));
    return allocator.rawAlloc(len, alignment, ret_addr);
}
fn poolResize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const allocator: *std.mem.Allocator = @ptrCast(@alignCast(ctx));
    return allocator.rawResize(memory, alignment, new_len, ret_addr);
}
fn poolRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const allocator: *std.mem.Allocator = @ptrCast(@alignCast(ctx));
    _ = alignment;
    _ = ret_addr;
    if (new_len == 0) {
        allocator.free(memory);
        return memory[0..0];
    }
    return null;
}
fn poolFree(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}

const pool_vtable = std.mem.Allocator.VTable{
    .alloc = poolAlloc,
    .resize = poolResize,
    .remap = poolRemap,
    .free = poolFree,
};

const POOL_SIZE: usize = 4;

pub const VideoDecoder = struct {
    allocator: std.mem.Allocator,
    fmt: ?*c.AVFormatContext,
    video_stream: c_int,
    codec: ?*const c.AVCodec,
    ctx: ?*c.AVCodecContext,
    sws: ?*c.SwsContext,
    frame: ?*c.AVFrame,
    pkt: ?*c.AVPacket,
    width: u32,
    height: u32,
    fps: f64,
    eof: bool,
    pool_index: usize = 0,
    pool_frames: [POOL_SIZE]Img,

    /// Open `path` for decoding. Caller must call `deinit` when done.
    pub fn open(allocator: std.mem.Allocator, path: [*:0]const u8) VideoError!VideoDecoder {
        ensureNetworkInit();

        // -- format context --
        var fmt: ?*c.AVFormatContext = null;
        if (c.avformat_open_input(&fmt, path, null, null) != 0)
            return error.FormatOpenFailed;

        if (c.avformat_find_stream_info(fmt, null) < 0) {
            c.avformat_close_input(&fmt);
            return error.StreamInfoFailed;
        }

        // -- find video stream --
        const nb_streams = fmt.?.nb_streams;
        var video_stream: c_int = -1;
        var i: c_uint = 0;
        while (i < nb_streams) : (i += 1) {
            const st = fmt.?.streams[i];
            if (st.*.codecpar.*.codec_type == c.AVMEDIA_TYPE_VIDEO) {
                video_stream = @intCast(i);
                break;
            }
        }
        if (video_stream < 0) {
            c.avformat_close_input(&fmt);
            return error.NoVideoStream;
        }

        // -- find & open decoder --
        const st = fmt.?.streams[@as(usize, @intCast(video_stream))];
        const codec = c.avcodec_find_decoder(st.*.codecpar.*.codec_id) orelse {
            c.avformat_close_input(&fmt);
            return error.CodecNotFound;
        };

        var ctx = c.avcodec_alloc_context3(codec) orelse {
            c.avformat_close_input(&fmt);
            return error.CodecAllocFailed;
        };

        if (c.avcodec_parameters_to_context(ctx, st.*.codecpar) < 0) {
            c.avcodec_free_context(&ctx);
            c.avformat_close_input(&fmt);
            return error.CodecParamsFailed;
        }
        if (c.avcodec_open2(ctx, codec, null) < 0) {
            c.avcodec_free_context(&ctx);
            c.avformat_close_input(&fmt);
            return error.CodecOpenFailed;
        }

        // Enable slice-based multi-threaded decoding.
        ctx[0].thread_count = @intCast(std.Thread.getCpuCount() catch 1);
        ctx[0].thread_type = FF_THREAD_SLICE;

        const width: u32 = @intCast(ctx[0].width);
        const height: u32 = @intCast(ctx[0].height);

        // FPS: prefer r_frame_rate (true codec timing) over avg_frame_rate
        const fps_val: f64 = blk: {
            if (st.*.r_frame_rate.num != 0 and st.*.r_frame_rate.den != 0) {
                break :blk @as(f64, @floatFromInt(st.*.r_frame_rate.num)) /
                    @as(f64, @floatFromInt(st.*.r_frame_rate.den));
            } else if (st.*.avg_frame_rate.num != 0 and st.*.avg_frame_rate.den != 0) {
                break :blk @as(f64, @floatFromInt(st.*.avg_frame_rate.num)) /
                    @as(f64, @floatFromInt(st.*.avg_frame_rate.den));
            } else {
                break :blk 30.0;
            }
        };

        // -- colourspace converter: native -> BGR24 --
        const sws = c.sws_getContext(
            @intCast(width),
            @intCast(height),
            ctx[0].pix_fmt,
            @intCast(width),
            @intCast(height),
            c.AV_PIX_FMT_BGR24,
            SWS_BILINEAR,
            null,
            null,
            null,
        ) orelse {
            c.avcodec_free_context(&ctx);
            c.avformat_close_input(&fmt);
            return error.SwsAllocFailed;
        };

        // -- frame & packet --
        var frame = c.av_frame_alloc();
        var pkt = c.av_packet_alloc();
        if (frame == null or pkt == null) {
            c.av_frame_free(&frame);
            c.av_packet_free(&pkt);
            c.sws_freeContext(sws);
            c.avcodec_free_context(&ctx);
            c.avformat_close_input(&fmt);
            return error.FrameAllocFailed;
        }

        // Pre-allocate frame pool to avoid per-frame malloc in decode loop.
        var pool_frames: [POOL_SIZE]Img = undefined;
        var j: usize = 0;
        while (j < POOL_SIZE) : (j += 1) {
            pool_frames[j] = Img.init(allocator, width, height, 3) catch {
                c.av_frame_free(&frame);
                c.av_packet_free(&pkt);
                c.sws_freeContext(sws);
                c.avcodec_free_context(&ctx);
                c.avformat_close_input(&fmt);
                return error.FrameAllocFailed;
            };
        }

        return VideoDecoder{
            .allocator = allocator,
            .fmt = fmt,
            .video_stream = video_stream,
            .codec = codec,
            .ctx = ctx,
            .sws = sws,
            .frame = frame,
            .pkt = pkt,
            .width = width,
            .height = height,
            .fps = fps_val,
            .eof = false,
            .pool_index = 0,
            .pool_frames = pool_frames,
        };
    }

    pub fn getWidth(self: *const VideoDecoder) u32 {
        return self.width;
    }

    pub fn getHeight(self: *const VideoDecoder) u32 {
        return self.height;
    }

    pub fn getFps(self: *const VideoDecoder) f64 {
        return self.fps;
    }

    /// Decode the next frame into a newly-allocated `Img` (BGR24, channels==3).
    /// Returns `end_of_stream` when no more frames are available.
    pub fn next(self: *VideoDecoder) VideoError!NextResult {
        if (self.eof) return NextResult{ .end_of_stream = {} };

        while (true) {
            // Read the next packet from the container.
            const read_ret = c.av_read_frame(self.fmt, self.pkt);
            if (read_ret == AVERROR_EOF) {
                self.eof = true;
                return NextResult{ .end_of_stream = {} };
            }
            if (read_ret == AVERROR_EAGAIN) {
                c.av_packet_unref(self.pkt);
                continue;
            }
            if (read_ret < 0) {
                return error.EncodeSendFailed;
            }

            // Skip non-video packets.
            if (self.pkt.?.stream_index != self.video_stream) {
                c.av_packet_unref(self.pkt);
                continue;
            }

            // Send packet to decoder.
            const send_ret = c.avcodec_send_packet(self.ctx, self.pkt);
            c.av_packet_unref(self.pkt);
            if (send_ret < 0) continue;

            // Drain all available frames from the decoder.
            while (send_ret >= 0) {
                const recv_ret = c.avcodec_receive_frame(self.ctx, self.frame);
                if (recv_ret == AVERROR_EAGAIN or recv_ret == AVERROR_EOF) break;
                if (recv_ret < 0) return error.EncodeSendFailed;

                // Got a frame — convert to BGR24 using the frame pool.
                const pool_idx = self.pool_index;
                self.pool_index = (self.pool_index + 1) % POOL_SIZE;
                var img = self.pool_frames[pool_idx];
                img.allocator = .{
                    .ptr = &self.allocator,
                    .vtable = &pool_vtable,
                };

                var dst_slices: [1][*]u8 = .{img.pixels.ptr};
                var dst_stride: [1]c_int = .{@intCast(img.stride)};

                _ = c.sws_scale(
                    self.sws,
                    @ptrCast(&self.frame.?.data),
                    @ptrCast(&self.frame.?.linesize),
                    0,
                    @intCast(self.frame.?.height),
                    @ptrCast(&dst_slices),
                    @ptrCast(&dst_stride),
                );

                c.av_frame_unref(self.frame);
                return NextResult{ .frame = img };
            }
        }
    }

    pub fn deinit(self: *VideoDecoder) void {
        // Free pool frame pixel buffers.
        var i: usize = 0;
        while (i < POOL_SIZE) : (i += 1) {
            if (self.pool_frames[i].pixels.len > 0) {
                self.allocator.free(self.pool_frames[i].pixels);
                self.pool_frames[i].pixels = &.{};
            }
        }
        c.sws_freeContext(self.sws);
        c.av_frame_free(&self.frame);
        c.av_packet_free(&self.pkt);
        c.avcodec_free_context(&self.ctx);
        c.avformat_close_input(&self.fmt);
    }
};

// =========================================================================
//  VideoEncoder
// =========================================================================

pub const VideoEncoder = struct {
    allocator: std.mem.Allocator,
    fmt: ?*c.AVFormatContext,
    stream: ?*c.AVStream,
    codec: ?*const c.AVCodec,
    ctx: ?*c.AVCodecContext,
    sws_bgr: ?*c.SwsContext, // BGR24 -> dst_pix_fmt
    sws_gray: ?*c.SwsContext, // GRAY8 -> dst_pix_fmt (avoids BGR expansion)
    frame: ?*c.AVFrame,
    pkt: ?*c.AVPacket,
    width: u32,
    height: u32,
    dst_pix_fmt: c_int,

    /// Open an encoder writing to `path`.
    /// `pix_fmt_name` — e.g. "yuv422p10le" or "gray".
    /// `codec_name`   — e.g. "prores_ks", or null to let the muxer decide.
    pub fn open(
        allocator: std.mem.Allocator,
        path: [*:0]const u8,
        w: u32,
        h: u32,
        fps: f64,
        pix_fmt_name: [*:0]const u8,
        codec_name: ?[*:0]const u8,
    ) VideoError!VideoEncoder {
        const dst_pix_fmt = c.av_get_pix_fmt(pix_fmt_name);

        // -- guess output format --
        var ofmt: ?*const c.AVOutputFormat = c.av_guess_format(null, path, null);
        if (ofmt == null and codec_name != null) {
            ofmt = c.av_guess_format(codec_name.?, null, null);
        }
        if (ofmt == null) {
            ofmt = c.av_guess_format("mp4", null, null);
        }
        if (ofmt == null) return error.OutputFormatNotFound;

        // -- find encoder --
        var codec: ?*const c.AVCodec = if (codec_name != null)
            c.avcodec_find_encoder_by_name(codec_name.?)
        else
            null;
        if (codec == null) {
            codec = c.avcodec_find_encoder(ofmt.?.video_codec);
        }
        if (codec == null) return error.CodecEncoderNotFound;

        // -- allocate output format context --
        var fmt_ctx: ?*c.AVFormatContext = null;
        if (c.avformat_alloc_output_context2(&fmt_ctx, ofmt.?, null, path) < 0)
            return error.FormatOpenFailed;

        // -- codec context --
        var ctx = c.avcodec_alloc_context3(codec) orelse {
            c.avformat_free_context(fmt_ctx);
            return error.CodecAllocFailed;
        };

        ctx[0].width = @intCast(w);
        ctx[0].height = @intCast(h);
        ctx[0].pix_fmt = dst_pix_fmt;
        const fps_int: c_int = if (fps > 0) @intFromFloat(fps) else 30;
        ctx[0].time_base = .{ .num = 1, .den = fps_int };

        if ((ofmt.?.flags & AVFMT_GLOBALHEADER) != 0)
            ctx[0].flags |= AV_CODEC_FLAG_GLOBAL_HEADER;

        // Threading: hardware encoders handle it internally, software benefits from slice MT.
        const is_hw = blk: {
            const name_str = if (codec_name != null) std.mem.span(codec_name.?) else "";
            break :blk (std.mem.indexOf(u8, name_str, "videotoolbox") != null or
                std.mem.indexOf(u8, name_str, "vaapi") != null or
                std.mem.indexOf(u8, name_str, "nvenc") != null or
                std.mem.indexOf(u8, name_str, "amf") != null);
        };
        if (is_hw) {
            _ = c.av_opt_set_double(ctx[0].priv_data, "q", 80.0, 0);
        } else {
            const ncores = std.Thread.getCpuCount() catch 1;
            ctx[0].thread_count = @intCast(ncores);
            ctx[0].thread_type = FF_THREAD_SLICE;
        }

        if (c.avcodec_open2(ctx, codec, null) < 0) {
            c.avcodec_free_context(&ctx);
            c.avformat_free_context(fmt_ctx);
            return error.CodecOpenFailed;
        }

        // -- stream --
        const stream = c.avformat_new_stream(fmt_ctx, null) orelse {
            c.avcodec_free_context(&ctx);
            c.avformat_free_context(fmt_ctx);
            return error.StreamCreateFailed;
        };
        _ = c.avcodec_parameters_from_context(stream[0].codecpar, ctx);
        stream[0].time_base = ctx[0].time_base;

        // -- open file for writing --
        if ((ofmt.?.flags & AVFMT_NOFILE) == 0) {
            if (c.avio_open(&fmt_ctx.?.pb, path, AVIO_FLAG_WRITE) < 0) {
                c.avcodec_free_context(&ctx);
                c.avformat_free_context(fmt_ctx);
                return error.FormatOpenWriteFailed;
            }
        }

        if (c.avformat_write_header(fmt_ctx, null) < 0) {
            _ = c.avio_closep(&fmt_ctx.?.pb);
            c.avcodec_free_context(&ctx);
            c.avformat_free_context(fmt_ctx);
            return error.FormatHeaderFailed;
        }

        // -- colour-space converters --
        const sws_bgr = c.sws_getContext(
            @intCast(w),
            @intCast(h),
            c.AV_PIX_FMT_BGR24,
            @intCast(w),
            @intCast(h),
            dst_pix_fmt,
            SWS_BILINEAR,
            null,
            null,
            null,
        );
        const sws_gray = c.sws_getContext(
            @intCast(w),
            @intCast(h),
            c.AV_PIX_FMT_GRAY8,
            @intCast(w),
            @intCast(h),
            dst_pix_fmt,
            SWS_BILINEAR,
            null,
            null,
            null,
        );

        var frame = c.av_frame_alloc();
        if (sws_bgr == null or sws_gray == null or frame == null) {
            c.sws_freeContext(sws_bgr);
            c.sws_freeContext(sws_gray);
            c.av_frame_free(&frame);
            _ = c.avio_closep(&fmt_ctx.?.pb);
            c.avcodec_free_context(&ctx);
            c.avformat_free_context(fmt_ctx);
            return error.SwsAllocFailed;
        }

        frame[0].format = dst_pix_fmt;
        frame[0].width = @intCast(w);
        frame[0].height = @intCast(h);
        frame[0].pts = 0;

        if (c.av_frame_get_buffer(frame, 0) < 0) {
            c.sws_freeContext(sws_bgr);
            c.sws_freeContext(sws_gray);
            c.av_frame_free(&frame);
            c.avcodec_free_context(&ctx);
            c.avformat_free_context(fmt_ctx);
            return error.FrameBufferFailed;
        }

        const pkt = c.av_packet_alloc();

        return VideoEncoder{
            .allocator = allocator,
            .fmt = fmt_ctx,
            .stream = stream,
            .codec = codec,
            .ctx = ctx,
            .sws_bgr = sws_bgr,
            .sws_gray = sws_gray,
            .frame = frame,
            .pkt = pkt,
            .width = w,
            .height = h,
            .dst_pix_fmt = dst_pix_fmt,
        };
    }

    /// Encode one frame. Accepts either 3-channel BGR24 or 1-channel GRAY8.
    pub fn write(self: *VideoEncoder, in_frame: *const Img) VideoError!void {
        const sws: ?*c.SwsContext = if (in_frame.channels == 1) self.sws_gray else if (in_frame.channels == 3) self.sws_bgr else return error.EncodeSendFailed;

        var src_slices: [1][*]const u8 = .{in_frame.pixels.ptr};
        var src_stride: [1]c_int = .{@intCast(in_frame.stride)};

        _ = c.sws_scale(
            sws,
            @ptrCast(&src_slices),
            @ptrCast(&src_stride),
            0,
            @intCast(in_frame.h),
            @ptrCast(&self.frame.?.data),
            @ptrCast(&self.frame.?.linesize),
        );

        const ret = c.avcodec_send_frame(self.ctx, self.frame);
        self.frame.?.pts += 1;
        if (ret < 0) return error.EncodeSendFailed;

        while (true) {
            const recv_ret = c.avcodec_receive_packet(self.ctx, self.pkt);
            if (recv_ret == AVERROR_EAGAIN or recv_ret == AVERROR_EOF) break;
            if (recv_ret < 0) return error.EncodeSendFailed;

            c.av_packet_rescale_ts(self.pkt, self.ctx.?.time_base, self.stream.?.time_base);
            self.pkt.?.stream_index = self.stream.?.index;
            _ = c.av_interleaved_write_frame(self.fmt, self.pkt);
            c.av_packet_unref(self.pkt);
        }
    }

    /// Flush encoder, write trailer, and release all resources.
    pub fn deinit(self: *VideoEncoder) void {
        // Flush remaining packets.
        _ = c.avcodec_send_frame(self.ctx, null);
        while (true) {
            const ret = c.avcodec_receive_packet(self.ctx, self.pkt);
            if (ret < 0) break;
            c.av_packet_rescale_ts(self.pkt, self.ctx.?.time_base, self.stream.?.time_base);
            self.pkt.?.stream_index = self.stream.?.index;
            _ = c.av_interleaved_write_frame(self.fmt, self.pkt);
            c.av_packet_unref(self.pkt);
        }

        _ = c.av_write_trailer(self.fmt);

        if ((self.fmt.?.oformat[0].flags & AVFMT_NOFILE) == 0)
            _ = c.avio_closep(&self.fmt.?.pb);

        c.sws_freeContext(self.sws_bgr);
        c.sws_freeContext(self.sws_gray);
        c.av_frame_free(&self.frame);
        c.av_packet_free(&self.pkt);
        c.avcodec_free_context(&self.ctx);
        c.avformat_free_context(self.fmt);
    }
};

// =========================================================================
//  Hardware encoder probing
// =========================================================================

/// Probe for hardware-accelerated encoders.
/// Returns the name of the best available HW encoder, or null if none found.
/// Caller should fall back to software (e.g. "prores_ks") when null.
pub fn probeHwEncoder() ?[*:0]const u8 {
    if (builtin.os.tag == .macos) {
        if (c.avcodec_find_encoder_by_name("hevc_videotoolbox") != null) return "hevc_videotoolbox";
        if (c.avcodec_find_encoder_by_name("h264_videotoolbox") != null) return "h264_videotoolbox";
    } else if (builtin.os.tag == .linux) {
        if (c.avcodec_find_encoder_by_name("hevc_vaapi") != null) return "hevc_vaapi";
        if (c.avcodec_find_encoder_by_name("h264_vaapi") != null) return "h264_vaapi";
    }

    return null;
}

// =========================================================================
//  Single-image loader (uses FFmpeg to decode any image format)
// =========================================================================

/// Load a single image file (PNG, JPEG, TIFF, BMP, etc.) into an `Img`.
/// The returned `Img` is BGR24 (channels==3). Caller must call `img.deinit()`.
pub fn imageLoad(allocator: std.mem.Allocator, path: [*:0]const u8) VideoError!Img {
    // -- format context --
    var fmt: ?*c.AVFormatContext = null;
    if (c.avformat_open_input(&fmt, path, null, null) != 0)
        return error.FormatOpenFailed;

    if (c.avformat_find_stream_info(fmt, null) < 0) {
        c.avformat_close_input(&fmt);
        return error.StreamInfoFailed;
    }

    // -- find video stream --
    const nb_streams = fmt.?.nb_streams;
    var video_stream: c_int = -1;
    var i: c_uint = 0;
    while (i < nb_streams) : (i += 1) {
        if (fmt.?.streams[i].*.codecpar.*.codec_type == c.AVMEDIA_TYPE_VIDEO) {
            video_stream = @intCast(i);
            break;
        }
    }
    if (video_stream < 0) {
        c.avformat_close_input(&fmt);
        return error.NoVideoStream;
    }

    // -- find & open decoder --
    const st = fmt.?.streams[@as(usize, @intCast(video_stream))];
    const codec = c.avcodec_find_decoder(st.*.codecpar.*.codec_id) orelse {
        c.avformat_close_input(&fmt);
        return error.CodecNotFound;
    };

    var ctx = c.avcodec_alloc_context3(codec) orelse {
        c.avformat_close_input(&fmt);
        return error.CodecAllocFailed;
    };
    if (c.avcodec_parameters_to_context(ctx, st.*.codecpar) < 0) {
        c.avcodec_free_context(&ctx);
        c.avformat_close_input(&fmt);
        return error.CodecParamsFailed;
    }
    if (c.avcodec_open2(ctx, codec, null) < 0) {
        c.avcodec_free_context(&ctx);
        c.avformat_close_input(&fmt);
        return error.CodecOpenFailed;
    }

    // -- colourspace converter: native -> BGR24 --
    const sws = c.sws_getContext(
        ctx[0].width,
        ctx[0].height,
        ctx[0].pix_fmt,
        ctx[0].width,
        ctx[0].height,
        c.AV_PIX_FMT_BGR24,
        SWS_BILINEAR,
        null,
        null,
        null,
    ) orelse {
        c.avcodec_free_context(&ctx);
        c.avformat_close_input(&fmt);
        return error.SwsAllocFailed;
    };

    // -- frame & packet --
    var frame = c.av_frame_alloc();
    var pkt = c.av_packet_alloc();
    if (frame == null or pkt == null) {
        c.av_frame_free(&frame);
        c.av_packet_free(&pkt);
        c.sws_freeContext(sws);
        c.avcodec_free_context(&ctx);
        c.avformat_close_input(&fmt);
        return error.FrameAllocFailed;
    }

    // Read packets until we decode the first frame.
    var got_frame = false;
    while (c.av_read_frame(fmt, pkt) >= 0) {
        if (pkt[0].stream_index != video_stream) {
            c.av_packet_unref(pkt);
            continue;
        }
        const send_ret = c.avcodec_send_packet(ctx, pkt);
        c.av_packet_unref(pkt);
        if (send_ret < 0) continue;
        const recv_ret = c.avcodec_receive_frame(ctx, frame);
        if (recv_ret == 0) {
            got_frame = true;
            break;
        }
        if (recv_ret == AVERROR_EOF) break;
    }

    // Flush decoder (some image formats deliver only on flush).
    if (!got_frame) {
        _ = c.avcodec_send_packet(ctx, null);
        if (c.avcodec_receive_frame(ctx, frame) == 0) got_frame = true;
    }

    var result: VideoError!Img = error.FormatOpenFailed;

    if (got_frame) {
        const w: u32 = @intCast(ctx[0].width);
        const h: u32 = @intCast(ctx[0].height);
        const img = Img.init(allocator, w, h, 3) catch {
            c.av_frame_free(&frame);
            c.av_packet_free(&pkt);
            c.sws_freeContext(sws);
            c.avcodec_free_context(&ctx);
            c.avformat_close_input(&fmt);
            return error.FrameBufferFailed;
        };

        var dst_slices: [1][*]u8 = .{img.pixels.ptr};
        var dst_stride: [1]c_int = .{@intCast(img.stride)};

        _ = c.sws_scale(
            sws,
            @ptrCast(&frame[0].data),
            @ptrCast(&frame[0].linesize),
            0,
            @intCast(frame[0].height),
            @ptrCast(&dst_slices),
            @ptrCast(&dst_stride),
        );

        result = img;
    }

    // Cleanup temporaries.
    c.av_frame_free(&frame);
    c.av_packet_free(&pkt);
    c.sws_freeContext(sws);
    c.avcodec_free_context(&ctx);
    c.avformat_close_input(&fmt);

    if (!got_frame) return error.FormatOpenFailed;
    return result;
}

// =========================================================================
//  Tests
// =========================================================================

test "fferrtag constants match expected values" {
    // AVERROR_EOF should be negative
    try std.testing.expect(AVERROR_EOF < 0);
    // AVERROR_EAGAIN should be negative
    try std.testing.expect(AVERROR_EAGAIN < 0);
    // They should be different values
    try std.testing.expect(AVERROR_EOF != AVERROR_EAGAIN);
}

test "probeHwEncoder returns null or a valid name" {
    const result = probeHwEncoder();
    if (result) |name| {
        const slice = std.mem.span(name);
        try std.testing.expect(slice.len > 0);
    }
}
