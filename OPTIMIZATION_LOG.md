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
