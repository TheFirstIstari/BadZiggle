# BadZiggle Port Completion Design

## Objective
Complete the Zig port of BadApplestein to be feature-complete with the C implementation, focusing on image processing (PDF support deferred).

## Current State
- ~4.5K lines of well-structured Zig code
- CLI, video I/O, image ops, SIMD matching, greedy block solver, atlas cache all working
- Two critical gaps prevent end-to-end functionality

## Gap 1: Source Image Renderer

### Problem
The render stage can't produce image tiles - only solid fills (black/white). The `SourceRenderer` callback pattern exists in `render.zig:44-47` but returns `null`.

### Solution
Implement concrete source renderer that:
1. Looks up `op_id` in registry to get `(pdf_path, page_idx)`
2. Loads image file via FFmpeg (`video.imageLoad`)
3. Scales to tile dimensions
4. Returns pixel buffer for blitting

### Implementation Steps
1. Add `loadImageForTile` function in `render.zig`
2. Wire up `SourceRenderer` callback in `encode` function
3. Add registry lookup using existing `Registry` type
4. Handle edge cases (missing files, invalid indices)

### Files to Modify
- `src/render.zig` - Add image loading, wire up callback
- `src/video.zig` - Verify `imageLoad` works correctly

## Gap 2: Multi-Threading

### Problem
Arrange and render stages run single-threaded. The `--threads` CLI flag exists but isn't wired up.

### Solution
Enable parallelism in two stages:

#### Arrange Stage (match.zig)
- Use `std.Thread.spawn` for batch matching
- Divide pages across threads
- Join threads and merge results

#### Render Stage (render.zig)
- Already has threaded encode pipeline
- Add parallel frame assembly using thread pool

### Implementation Steps
1. Wire `--threads` flag to `match.setThreads()`
2. Implement thread pool in `match.zig` for batch matching
3. Add parallel frame assembly in `render.zig`
4. Use `std.Thread.getCpuCount()` for default thread count

### Files to Modify
- `src/match.zig` - Add thread pool for batch matching
- `src/render.zig` - Add parallel frame assembly
- `src/main.zig` - Wire `--threads` flag

## Testing Plan

### Unit Tests
- Test `loadImageForTile` with sample images
- Test thread pool with mock matching function
- Run existing tests to ensure no regressions

### Integration Test
1. Build library from sample images
2. Run arrange stage on test video
3. Run render stage to produce output
4. Compare output with C implementation

### Benchmark
- Run `badapplebench` suite comparing C vs Zig
- Track performance across versions

## Success Criteria
1. End-to-end pipeline works: `badziggle input.mp4 output.mov`
2. Output matches C implementation (visual comparison)
3. All existing tests pass
4. New tests added for renderer and threading
5. Performance within 20% of C implementation

## Deferred Work
- PDF support (requires MuPDF bindings)
- Full AVX2 SIMD (current 16-byte works on ARM/x86)
- Hardware encoding (VideoToolbox/VAAPI)
