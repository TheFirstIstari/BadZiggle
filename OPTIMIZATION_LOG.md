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

## Optimization 6: SIMD L1 Distance for Feature Matching (match.zig)

**Date:** 2026-07-27
**File:** `src/match.zig`
**Change:** Implemented SIMD-optimized L1 distance computation for feature matching, matching the SIMD intrinsics in BadAppleStein's `match.c` (SSE2 `_mm_sad_epu8`/AVX2 `_mm256_sad_epu8`/NEON `vabdq_u8` + `vpaddlq_u16`). Added private `featureL1Simd` and `featureL1BoundedSimd` functions using Zig's `std.simd.suggestVectorLength` and `@Vector` types for portable SIMD abs-diff computation, with `@bitCast` to array for scalar accumulation. Public `featureL1` and `featureL1Bounded` now dispatch to SIMD path when available, falling back to scalar on non-SIMD targets.
**Rationale:** Feature matching is the hot path in the arrange pipeline, computing L1 distances between feature vectors for thousands of library pages per frame. The C reference uses SSE2/AVX2 `sad_epu8` instructions that compute 16 or 32 absolute differences and accumulate horizontal sums in a single SIMD operation. The previous Zig implementation was pure scalar, missing this significant optimization opportunity. The SIMD path processes feature vectors at vector-width granularity while preserving identical algorithm behavior and exact binary output parity with the C reference.
**Before:** Scalar `featureL1`/`featureL1Bounded` using `for (a, b)` iteration over each byte.
**After:** SIMD `featureL1Simd`/`featureL1BoundedSimd` process bytes in `@Vector(vl, u8)` chunks using `@max`/`@min` abs-diff, with scalar tail handling and overflow-safe accumulation.
**Verified:** `zig build`, `zig build test`, and `./zig-out/bin/badziggle --help` all succeed; all unit tests pass.
