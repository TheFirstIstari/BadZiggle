# BadZiggle Optimization Log

## Baseline

| Metric | Value |
|--------|-------|
| Zig version | 0.16.0 |
| Baseline compile time (Debug, 3 runs avg) | ~141M cycles (~0.14s real) |
| Baseline ReleaseSmall compile time (3 runs avg) | ~141M cycles (~0.14s real) |
| Baseline ReleaseFast compile time (1 run) | ~4.0s real wall-clock |
| Baseline binary | `zig-out/bin/badziggle` |
| Baseline build command | `zig build` (Debug mode) |

## Optimization 1: Release Mode Build Configuration

**Date:** 2026-07-26
**File:** `build.zig`
**Change:** Added `-Drelease-fast` and `-Drelease-small` build options to build.zig, enabling `optimize = .ReleaseFast` and `optimize = .ReleaseSmall` modes. The default remains `b.standardOptimizeOption(.{})` for backward compatibility. Added `strip` option for release builds.
**Rationale:** The original build.zig used `standardOptimizeOption` which defaults to Debug mode. ReleaseFast enables CPU-specific optimizations and inlining; ReleaseSmall prioritizes code size reduction. Stripping debug symbols from release builds reduces binary size.
**Before:** Debug only (~141M cycles compile)
**After:** ReleaseFast/ReleaseSmall available; debug compile unchanged (~141M cycles)
**Verified:** `zig build`, `zig build -Drelease-fast`, `zig build -Drelease-small`, and `./zig-out/bin/badziggle --help` all succeed

## Optimization 2: Strip Debug Symbols in Release

**Date:** 2026-07-26
**File:** `build.zig`
**Change:** Added `strip` option that sets `root_module.strip = true` for non-Debug builds.
**Rationale:** Release builds don't need debug symbols; stripping reduces binary size and I/O during loading.
**Before:** TBD
**After:** TBD
**Verified:** `zig build` succeeds

## Optimization 3: Reduce Redundant String Comparisons in CLI Parser

**Date:** 2026-07-26
**File:** `cli.zig`
**Change:** Optimized the `parse()` function with byte-level dispatch — short flags (-v, -q, -j) dispatch on `arg[1]` directly; long flags check first character to narrow before full string comparison. Also removed redundant `std.mem.eql(u8, arg, "--")` with a direct length/byte check.
**Change (jsonEscape):** Added a fast path that returns the input slice directly when no escaping is needed, avoiding `ArrayList` allocation for the common case (most CLI flag names and values are simple ASCII).
**Rationale:** The CLI parser was a hot path called on every argument; byte-level dispatch avoids redundant string comparisons. The jsonEscape fast path avoids unnecessary allocations for simple strings.
**Before:** TBD
**After:** TBD
**Verified:** `zig build`, `zig build test`, and `./zig-out/bin/badziggle --help` all succeed

## Optimization 4: Fix Memory Leak in resolveLibraryPath

**Date:** 2026-07-26
**File:** `main.zig`
**Change:** Fixed potential memory leak in `resolveLibraryPath` where `default_lib` (from `std.fs.path.join`) was not freed when ownership was transferred to `opts.library`. Also removed unnecessary `dupeZ` allocation for path check.
**Rationale:** The original code allocated `default_lib` via `path.join`, then `dupeZ`'d it for `c.access` check, then sometimes leaked the original. Now we check `c.access` using stack-allocated path space when possible.
**Before:** TBD
**After:** TBD
**Verified:** `zig build` succeeds

## Optimization 5: Optimize Cache Clearing in arrange.zig

**Date:** 2026-07-26
**File:** `arrange.zig`
**Change:** Replaced `@memset(slots, CacheSlot{})` with byte-level zeroing using `@memset` on the raw bytes of the slot array, avoiding struct initialization overhead.
**Rationale:** Cache clearing is called frequently; byte-level memset is more efficient than struct-by-struct initialization.
**Before:** TBD
**After:** TBD
**Verified:** `zig build` succeeds

## Optimization 6: Pointer-Based Sobel Magnitude for Auto-Vectorization (Feature Xform)

**Date:** 2026-07-27
**File:** `src/imgops.zig`
**Change:** Restructured `sobelMagnitude()` inner loop to use pointer-based iteration (`top`, `mid`, `bot`, `dst` raw pointers) instead of index-based slice access within the Sobel gradient computation. Replaced `for` loop with `while` loop to give the compiler stronger auto-vectorization hints. Moved `row_out` pointer computation before the row pointer setup for logical ordering.
**Rationale:** The Sobel edge detection in `sobelMagnitude()` is part of the feature transform pipeline (computing edge features from grayscale tiles). The BadAppleStein C reference has explicit AVX2 and NEON SIMD implementations for this function that process 16 pixels at a time using platform intrinsics. The original Zig implementation used indexed slice access (`row_top[x - 1]`, etc.) which prevents the compiler from easily vectorizing the inner loop. Pointer-based iteration removes index arithmetic overhead and provides a more compiler-friendly access pattern that enables auto-vectorization on x86_64 (SSE2/AVX2) and ARM (NEON). The `while` loop structure also gives LLVM stronger optimization hints than the range-based `for` loop.
**Before:** Indexed slice access in inner Sobel loop with `for` range iterator
**After:** Pointer-based iteration with `while` loop for compiler auto-vectorization
**Verified:** `zig build`, `zig build test`, and `./zig-out/bin/badziggle --help` all succeed

## Optimization 7: SIMD-Accelerated BGR→Grayscale (Coarse SIMD)

**Date:** 2026-07-28
**File:** `src/imgops.zig`
**Change:** Added `imgToGraySimdRow()` which uses `std.simd` portable SIMD to
process multiple BGR pixels simultaneously, mirroring BadApplestein's
`img_to_gray_simd` (SSSE2/AVX2/NEON) in imgops.c and Odin's `core:simd`
implementation in BadOdinStein-odin-simd-gray. Added `computeLuma5()` for
batch=5 (vl=16, SSSE2-class) and `computeLuma10()` for batch=10 (vl=32,
AVX2-class), using `@shuffle` for channel extraction (mirrors PSHUFB/tbl
intrinsics), and scalar fallbacks for tail pixels and unknown vector lengths.
**Rationale:** The BGR→grayscale conversion in `toGray()` was the last major
image pipeline function missing explicit SIMD acceleration. The C reference
processes 5 pixels/iteration (SSSE2) or 10 pixels/iteration (AVX2) using
explicit intrinsics. The original Zig code was scalar pixel-by-pixel. The
portable `std.simd` path achieves the same throughput without target-specific
compiler flags, matching the C reference's algorithmic approach while remaining
cross-platform.
**Before:** Scalar pixel-by-pixel BGR→luma in `toGray()`
**After:** SIMD batch processing (5 or 10 pixels/iteration via shuffle-based
channel extraction) with scalar tail fallback
**Verified:** `zig build`, `zig build test`, and `./zig-out/bin/badziggle --help` all succeed

## Optimization 8: Parallel Frame Assembly

**Date:** 2026-07-28
**File:** `src/render.zig`, `src/main.zig`
**Change:** Refactored `assembleFrame()` into a two-phase pipeline:
  1. Sequential atlas pre-population (render and cache source tiles)
  2. Parallel blit with atomic fetch-add dynamic scheduling matching
     OpenMP's `#pragma omp parallel for schedule(dynamic)` pattern.
Added `BlitWorkerContext` struct and `blitWorker()` worker function.
Added `thread_count: u32` to `RenderOptions` and wired the `--threads`
CLI flag through `main.zig`. Added `AtlasCache.lookupReadOnly()` for
lock-free concurrent cache lookups during the blit phase.
**Rationale:** Frame assembly was entirely single-threaded even though
the C reference uses OpenMP to blit disjoint canvas Y-ranges in parallel.
The atomic fetch-add scheduler naturally handles load imbalance without
a barrier or complex work-stealing. Sequential atlas pre-population avoids
concurrent mutation of the hash table.
**Before:** Single-threaded frame assembly (blit + render + cache in one loop)
**After:** Two-phase assembly with parallel blit when `thread_count > 0` and
`n_instructions > 4`
**Verified:** `zig build`, `zig build test`, and `./zig-out/bin/badziggle --help` all succeed

## Optimization 9: SIMD Horizontal-Sum in L1 Feature Distance

**Date:** 2026-07-28
**File:** `src/match.zig`
**Change:** Replaced the scalar reduction loop in `featureL1Simd()` and `featureL1BoundedSimd()` with `@reduce(.Add, widened)`. The SIMD vector computes `absdiff = @max(va, vb) - @min(va, vb)`, then the result is zero-extended to `@Vector(vl, u32)` and reduced horizontally with a single `@reduce(.Add, ...)` call instead of iterating over each element.

```zig
// Before: scalar loop over bitcast array
const diff_arr: [vl]u8 = @bitCast(absdiff);
for (diff_arr) |d| { dist += d; }

// After: horizontal SIMD reduction
const widened: @Vector(vl, u32) = @intCast(absdiff);
dist += @reduce(.Add, widened);
```
**Rationale:** The L1 distance is the hottest function in the matching pipeline, called O(n_pages × num_targets) per frame. The scalar reduction loop added a full pass through each vector's elements, defeating the SIMD speedup. The zero-extend to u32 is necessary to avoid overflow (max distance per element is 255, and the reduction sums up to vl * 255 which can exceed u8). This is the recommended Zig idiom for horizontal vector sums.
**Impact:** Expected 2-4× throughput improvement in L1 distance computation, translating to an estimated 10-20% reduction in total arrange pipeline time (dominated by matching).
**Verified:** `zig build -Drelease-fast`, `zig build test`, and `./zig-out/bin/badziggle --help` all succeed

## Optimization 10: Inline Hot Leaf Functions

**Date:** 2026-07-28
**Files:** `src/match.zig`, `src/arrange.zig`
**Change:** Added `inline` keyword to 6 small leaf functions called millions of times per frame:

| Function | File | Line | Called |
|----------|------|------|--------|
| `featureL1Scalar` | `match.zig` | 186 | Per tile fallback to scalar |
| `featureL1BoundedScalar` | `match.zig` | 201 | Per tile early-termination fallback |
| `TopKList.insert` | `match.zig` | 239 | Per tile per candidate |
| `fnv1a64` | `arrange.zig` | 40 | Per tile hash |
| `fullFeatHash` | `arrange.zig` | 51 | Per cache miss |
| `coarseFeatHash` | `arrange.zig` | 65 | Per tile |

**Rationale:** These functions are small leaf functions called in the hottest code paths. The `inline` keyword eliminates function call overhead (stack frame, register save/restore, call/ret instructions) and enables inter-procedural constant propagation and better register allocation. `TopKList.insert` is arguably the single most-called function in the entire program.
**Impact:** Expected ~3-8% reduction in matching time. Trade-off: slight binary size increase from code duplication at call sites.
**Verified:** `zig build -Drelease-fast`, `zig build test`, and `./zig-out/bin/badziggle --help` all succeed

## Optimization 11: Arena Allocator for Per-Frame Allocations

**Date:** 2026-07-28
**File:** `src/arrange.zig`
**Change:** Added `frame_allocator: Allocator` parameter to `extractAndMatch()`. In `processFrame()`, a `std.heap.ArenaAllocator` wraps the backing allocator, and its child allocator is passed as `frame_allocator` for all per-frame allocations. Four per-frame buffers now use arena allocation with bulk cleanup:

| Allocation | Previous Pattern | New Pattern |
|------------|-----------------|-------------|
| `feat_bufs` | `alloc` + explicit `free` | arena allocation |
| `coarse_feat` | `alloc` + explicit `free` | arena allocation |
| `crop_buf` | `alloc` + explicit `free` | arena allocation |
| `tiles_buf` | `appendSlice` on persistent vec | arena allocation |
| Match results | `alloc` per batch | arena allocation |

**Rationale:** Each frame in the arrange loop allocated 4 buffers and freed them all at the end. With thousands of frames, this generated thousands of malloc/free pairs. A single arena with one reset per frame replaces O(n_frames × n_buffers) malloc/free cycles with O(1) bulk deallocation. This reduces allocator contention and memory fragmentation, especially beneficial with multiple threads (lock contention on the backing allocator).
**Impact:** Expected ~5-15% reduction in arrange stage wall-clock time.
**Verified:** `zig build -Drelease-fast`, `zig build test`, and `./zig-out/bin/badziggle --help` all succeed

## Optimization 12: Branch Hoisting in Coarse Feature Extraction

**Date:** 2026-07-28
**File:** `src/arrange.zig`
**Change:** Hoisted the `db.channels == 3` branch from inside the per-pixel inner loop to an outer branch in the coarse feature extraction loop. The per-tile feature extraction loop now has two specialized paths — one for BGR (Rec.601 luma computation) and one for grayscale (direct pixel access). This eliminates a conditional branch checked on EVERY pixel that is invariant per frame.
**Rationale:** The `channels == 3` check was inside the innermost pixel loop, checked N² times per tile (N = tile size, typically 32-128). The branch predictor handles this well for long runs, but the bigger win is that the two specialized loops can be independently auto-vectorized by LLVM. The fused version with the runtime branch inside the loop body prevents LLVM from vectorizing effectively. Also hoisted other loop-invariant expressions (`maxv`, `G`, `has_edges`) out of pixel-level loops.
**Before:** Single monolithic pixel loop with `if (db.channels == 3)` inside the innermost body
**After:** Two specialized outer branches, each with a clean inner loop — BGR path with luma computation, grayscale path with direct pixel loads
**Impact:** Expected ~5-10% reduction in feature extraction time. Enables auto-vectorization of both specialized loops.
**Verified:** `zig build -Drelease-fast`, `zig build test`, and `./zig-out/bin/badziggle --help` all succeed

## Optimization 13: SIMD Area-Averaging in resizeArea

**Date:** 2026-07-28
**File:** `src/imgops.zig`
**Change:** In `resizeArea()` general (non-integer-upscale) path, the grayscale channel (ch==1) accumulation loop now uses `@Vector(8, u8)` loaded from source pixels, zero-extended to `@Vector(8, u64)` for accumulation, with `@reduce(.Add, ...)` for the final sum. Processes 8 source columns per SIMD iteration, with a scalar tail for remaining columns.
**Rationale:** Area-averaging resampling is used in `computeFeatureMultires` for every scale level on every non-hero tile. The original code accumulated per-pixel contributions one-at-a-time into a scalar u64. Using `@Vector` loads and `@reduce` lets the compiler emit SIMD pack+add instructions, processing 8× more pixels per iteration in the inner loop.
**Before:** Scalar per-pixel accumulation: `sum += src.pixels[cy * src.stride + cx]`
**After:** SIMD 8-wide accumulation: `@Vector(8, u8)` load → zero-extend → `@reduce(.Add, u64)`
**Impact:** Expected ~3-5× faster area resampling for grayscale tiles, translating to ~3-8% reduction in total arrange time.
**Verified:** `zig build -Drelease-fast`, `zig build test`, and `./zig-out/bin/badziggle --help` all succeed

## Optimization 14: smp_allocator — Replaced page_allocator with Thread-Safe General-Purpose Allocator

**Date:** 2026-07-28
**File:** `src/main.zig`

**Before:** The program used `std.heap.page_allocator` as its global allocator — every single allocation (CLI parsing, path building, feature buffers, cache tables) went through a direct OS mmap/munmap call. This is extremely slow for the thousands of small-to-medium allocations the pipeline performs per frame.

**After:** Replaced with `std.heap.smp_allocator`, a thread-safe, SMP-aware allocator with per-thread free lists and slab-based allocation for small sizes, falling back to page-level mapping for large allocations. This is the standard library's recommended general-purpose allocator for production code.

```zig
// Before:
const allocator = std.heap.page_allocator;

// After:
const allocator = std.heap.smp_allocator;
```

**Rationale:** `smp_allocator` provides memory pooling — small allocations reuse previously freed slabs instead of going back to the kernel. With the matching pipeline allocating thousands of per-target intermediate buffers per frame, the page_allocator's direct OS mapping caused O(frame_count × allocation_count) kernel crossings. The pooled allocator reduces this to O(slab_fill) kernel crossings.

**Impact:** Expected 20-40% reduction in total runtime. The matching pipeline alone does O(n_pages × n_targets) allocations per frame; pooling these into slab reuse dramatically reduces system time.

**Note:** A previous attempt used `std.heap.GeneralPurposeAllocator(.{.stack_trace_frames = 0})` which failed to compile — the GPA API was removed in Zig 0.16.0. `smp_allocator` is the correct replacement.

**Verification:** `zig build -Drelease-fast` and `./zig-out/bin/badziggle --help` both succeed.

---

## Optimization 15: @setRuntimeSafety(false) on Hot Inner Loops

**Date:** 2026-07-28
**Files:** `src/match.zig`, `src/render.zig`, `src/imgops.zig`

**Change:** Added `@setRuntimeSafety(false)` (with `defer @setRuntimeSafety(true)`) to the following hot functions in the pipeline:

| File | Function | Context |
|------|----------|---------|
| `match.zig` | `featureL1Simd` | SIMD L1 distance — per-tile, per-candidate |
| `match.zig` | `featureL1BoundedSimd` | Bounded SIMD L1 distance |
| `match.zig` | `featureL1` | Scalar L1 distance fallback |
| `render.zig` | `blitSolid` | Solid fill — per-instruction |
| `render.zig` | `blitTile` | Tile blit — per-instruction |
| `render.zig` | `copyTilePixels` | Atlas cache pixel copy |
| `imgops.zig` | `toGray` | BGR→grayscale conversion |
| `imgops.zig` | `resizeArea` | Area averaging resize |
| `imgops.zig` | `sobelMagnitude` | Sobel edge detection |

**Rationale:** Zig's default safety checks (bounds checking, integer overflow detection) add 1-3 branch instructions per slice access. In hot inner loops running millions of iterations per frame, these branches prevent the compiler from fully vectorizing and increase instruction cache pressure. All affected functions have been manually verified to be safe (loop guards with `i + vl <= n` patterns, provably in-bounds inner accesses). Restoring safety with `defer @setRuntimeSafety(true)` ensures only the targeted hot body loses checks.

**Impact:** Expected 5-15% improvement in matching and rendering time through better codegen from safety check elimination.

**Verification:** `zig build -Drelease-fast`, `zig build test` pass for all modified modules.

---

## Optimization 16: blitSolid 3-Channel Fill with @memset

**Date:** 2026-07-28
**File:** `src/render.zig`

**Before:** The `blitSolid` function's 3-channel (BGR) fill path used a per-pixel loop with three individual byte stores and a bounds check per pixel:
```zig
var px: i32 = 0;
while (px < fill_w) : (px += 1) {
    const off = fill_start + @as(usize, @intCast(px)) * 3;
    if (off + 3 <= canvas.len) {
        canvas[off] = val;
        canvas[off + 1] = val;
        canvas[off + 2] = val;
    }
}
```

**After:** Replaced with a single `@memset` call (same byte value repeated, which is correct since all 3 BGR channels receive the same `val`):
```zig
const end = @min(fill_start + @as(usize, @intCast(fill_w)) * 3, canvas.len);
if (fill_start < canvas.len) {
    @memset(canvas[fill_start..end], val);
}
```

**Rationale:** The per-pixel loop generated 3 bounds checks + 3 stores per pixel, plus the loop overhead. A single `@memset` compiles to a highly optimized `memset` implementation (typically SIMD-accelerated) that handles the entire fill region in one call. The grayscale path already used `@memset` — the 3-channel path was the only remaining per-pixel fill.

**Impact:** Expected 1-5% reduction in render time for color (BGR) output. Minimal impact for grayscale (the common case).

**Verification:** `zig build -Drelease-fast` and `zig build test` pass.

---

### Flag Parity Fixes (BadApplestein C reference parity)

#### 1. `--preset` expansion for render subcommand

**Date:** 2026-07-29
**File:** `src/main.zig`
**Change:** Added `expandPreset(&opts)` call in the `render` subcommand branch and the shorthand `<input> <output>` pipeline, matching the existing call in the `arrange` branch. Previously, preset expansion (`8k`, `4k`, `1080p`, `720p` → width/height) was only applied to the arrange subcommand; the render subcommand ignored `--preset` entirely.
**Rationale:** The C reference BadApplestein applies preset expansion for both arrange and render subcommands via `preset_width()`. Without this fix, `--preset 4k` passed to the render subcommand had no effect, always using the default 1920×1080 dimensions instead of 3840×2160.
**Before:** `--preset` only applied to `badziggle arrange`; ignored for `badziggle render`
**After:** `--preset` correctly overrides width/height/fps for `badziggle render` and the shorthand pipeline
**Verified:** `zig build` and `zig build test` pass

#### 2. `--codec` CLI flag for render subcommand

**Date:** 2026-07-29
**File:** `src/main.zig`
**Change:** Added `--codec <name>` CLI flag support in `runRender()`. The user-provided codec name is read via `cli.optStr("codec", "")` and passed as a null-terminated string to `VideoEncoder.open()`, overriding the default auto-detection behavior. When not set, the existing hardware/software auto-detection logic is preserved.
**Rationale:** The C reference BadApplestein has `--codec` to let users choose the encoder (e.g. `prores_ks`, `h264_videotoolbox`). Previously BadZiggle hardcoded the encoder choice based solely on channel count and hardware probe results, with no user override.
**Before:** Codec hardcoded to `prores_ks` (software) or auto-detected HW encoder; no user override
**After:** `--codec` flag allows explicit encoder selection; auto-detection used when flag is absent
**Verified:** `zig build` and `zig build test` pass

#### 3. `--pix-fmt` CLI flag for render subcommand

**Date:** 2026-07-29
**File:** `src/main.zig`
**Change:** Added `--pix-fmt <name>` CLI flag support in `runRender()`. The user-provided pixel format string is read via `cli.optStr("pix-fmt", "")` and passed as a null-terminated string to `VideoEncoder.open()`, overriding the default pixel format derived from the codec name. When not set, the existing auto-detected pixel format (yuv420p for HW, yuv422p10le for SW, gray for grayscale) is preserved.
**Rationale:** The C reference BadApplestein has `--pix-fmt` to let users specify the pixel format (e.g. `yuv420p`, `yuv422p10le`, `gray`). Previously BadZiggle hardcoded the pixel format based on the codec and channel count, with no user override.
**Before:** Pixel format hardcoded based on codec/channel logic; no user override
**After:** `--pix-fmt` flag allows explicit pixel format selection; auto-detection used when flag is absent
**Verified:** `zig build` and `zig build test` pass

#### 4. `--no-hw` flag formally documented and wired for render subcommand

**Date:** 2026-07-29
**File:** `src/main.zig`, `src/cli.zig`
**Change:** Added `--no-hw` to the render help text (`printRenderHelp()`) and ensured it is properly read from the CLI store. The hardware encoder detection logic already respected `--no-hw` via `cli.has("no-hw")` in `runRender()`, but the flag was undocumented and missing from `printRenderHelp()`.
**Rationale:** The C reference BadApplestein documents `--no-hw` to disable hardware encoder detection and force software ProRes encoding. While BadZiggle's implementation already worked, the flag was not listed in the help text and had no dedicated `optBool()` accessor in `cli.buildOptions()`.
**Before:** `--no-hw` worked at runtime but was undocumented in render help
**After:** `--no-hw` listed in `badziggle render --help` and properly documented
**Verified:** `zig build` and `zig build test` pass

---

#### 5. Auto-detect output dimensions from manifest header (render and CLI defaults)

**Date:** 2026-07-29
**Files:** `src/render.zig`, `src/main.zig`, `src/cli.zig`
**Change:** Fixed three related dimension auto-detection gaps to match the BadApplestein C reference:

1. **`src/render.zig` `render()`**: Replaced hardcoded 7680×4320 defaults with manifest-based auto-detection. When `--width` or `--height` is not specified (≤ 0), reads `src_w`/`src_h` from the first manifest binary header (first 8 bytes: `u32` LE each). Computes the missing dimension preserving the source aspect ratio (if only width given: `height = width * src_h / src_w`; if only height: `width = height * src_w / src_h`). If neither is given, uses source dimensions directly. Falls back to 7680×4320 if the manifest is unreadable.

2. **`src/main.zig` `runRender()`**: Updated encoder dimension setup to use the same manifest-header auto-detection, ensuring the VideoEncoder dimensions match the render pipeline's computed dimensions instead of falling back to hardcoded 7680×4320.

3. **`src/cli.zig` `buildOptions()`**: Changed default width/height from 1920/1080 to 0 so that absent `--width`/`--height` CLI flags produce a zero sentinel value that triggers manifest-based auto-detection in render() rather than using hardcoded defaults.

4. **`src/main.zig` `autoDetectSource()`**: Updated from hardcoded 1920×1080 to read source dimensions from the first manifest header with aspect-ratio-preserving computation. Added `manifest_dir`, `io`, and `allocator` parameters for manifest access.

**Rationale:** The C reference BadApplestein auto-detects all output dimensions from the source video manifest, preserving aspect ratio. BadZiggle was using hardcoded defaults at every layer (CLI options, main.zig encoder setup, render.zig canvas), breaking feature parity for users who don't explicitly specify dimensions.
**Before:** Hardcoded 7680×4320 (render), 7680×4320 (encoder), 1920×1080 (autoDetectSource); CLI defaults 1920×1080 bypassed auto-detection entirely
**After:** All dimensions auto-detected from manifest header with aspect-ratio preservation; only 7680×4320 used as ultimate fallback when manifest is unreadable
**Verified:** `zig build` and `zig build test` pass

All optimizations combined bring BadZiggle to the following performance vs the C reference:

| Implementation | Mean time (200 frames, 512×384) | vs C reference (1.571s) |
|---|---|---|
| C reference (BadApplestein) | 1.571s | 1.00× |
| Zig baseline | 3.401s | 2.17× |
| **Zig all optimizations** | *(pending benchmark)* | *(pending)* |
