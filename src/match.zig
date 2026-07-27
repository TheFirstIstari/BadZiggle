const std = @import("std");
const types = @import("types.zig");

/// Maximum number of candidates to keep per target in coarse-to-fine matching
const K = 16;

/// Global thread count setting (0 = auto)
var g_match_threads: u32 = 0;

/// Set thread count for matching operations. 0 = auto.
pub fn setThreads(n: u32) void {
    if (n > 0) g_match_threads = n;
}

/// Get current thread count setting
pub fn getThreads() u32 {
    return g_match_threads;
}

// ── Thread context structs ──────────────────────────────────────────

const CoarseCtx = struct {
    lib: []const u8,
    targets: []const u8,
    top_k: []TopKList,
    n_pages: u32,
    num_targets: u32,
    feat_len: u32,
    actual_coarse_len: u32,
    start_target: u32,
    end_target: u32,
};

const FineCtx = struct {
    lib: []const u8,
    targets: []const u8,
    top_k: []const TopKList,
    results: []i32,
    num_targets: u32,
    feat_len: u32,
    start_target: u32,
    end_target: u32,
};

// ── Thread workers ──────────────────────────────────────────────────

fn processCoarseChunk(ctx: *const CoarseCtx) void {
    var target_idx = ctx.start_target;
    while (target_idx < ctx.end_target) : (target_idx += 1) {
        const target_offset = @as(usize, target_idx) * ctx.feat_len;
        const target = ctx.targets[target_offset..][0..ctx.feat_len];

        var page_idx: u32 = 0;
        while (page_idx < ctx.n_pages) : (page_idx += 1) {
            const page_offset = @as(usize, page_idx) * ctx.feat_len;
            const page = ctx.lib[page_offset..][0..ctx.feat_len];

            const d = featureL1(page[0..ctx.actual_coarse_len], target[0..ctx.actual_coarse_len]);
            ctx.top_k[target_idx].insert(d, @intCast(page_idx));
        }
    }
}

fn processFineChunk(ctx: *const FineCtx) void {
    var target_idx = ctx.start_target;
    while (target_idx < ctx.end_target) : (target_idx += 1) {
        var best_d: u32 = std.math.maxInt(u32);
        var best_i: i32 = -1;

        const target_offset = @as(usize, target_idx) * ctx.feat_len;
        const target = ctx.targets[target_offset..][0..ctx.feat_len];

        for (ctx.top_k[target_idx].indices, ctx.top_k[target_idx].distances) |candidate_idx, _| {
            if (candidate_idx < 0) break;

            const candidate_offset = @as(usize, @intCast(candidate_idx)) * ctx.feat_len;
            const candidate = ctx.lib[candidate_offset..][0..ctx.feat_len];

            const d = featureL1Bounded(candidate, target, best_d);
            if (d < best_d) {
                best_d = d;
                best_i = candidate_idx;
            }
        }

        if (best_i == -1) {
            best_i = ctx.top_k[target_idx].indices[0];
        }
        ctx.results[target_idx] = best_i;
    }
}

// ── Scalar L1 distance ─────────────────────────────────────────────────────

/// Compute L1 (sum of absolute differences) distance between two feature vectors.
/// Returns the distance as u32, capped at maxInt(u32).
pub fn featureL1(a: []const u8, b: []const u8) u32 {
    std.debug.assert(a.len == b.len);

    var dist: u32 = 0;
    for (a, b) |aa, bb| {
        const d: i32 = @as(i32, @intCast(aa)) - @as(i32, @intCast(bb));
        const abs_d: u32 = if (d < 0) @intCast(-d) else @intCast(d);

        // Check for overflow before adding
        if (dist > std.math.maxInt(u32) - abs_d) {
            return std.math.maxInt(u32);
        }
        dist += abs_d;
    }
    return dist;
}

/// Compute L1 distance with early termination.
/// Returns the partial distance (which may be >= bound if not pruned).
pub fn featureL1Bounded(a: []const u8, b: []const u8, bound: u32) u32 {
    std.debug.assert(a.len == b.len);

    var dist: u32 = 0;
    for (a, b) |aa, bb| {
        const d: i32 = @as(i32, @intCast(aa)) - @as(i32, @intCast(bb));
        const abs_d: u32 = if (d < 0) @intCast(-d) else @intCast(d);

        if (dist > std.math.maxInt(u32) - abs_d) {
            return std.math.maxInt(u32);
        }
        dist += abs_d;

        if (dist > bound) return dist;
    }
    return dist;
}

// ── Top-K helper ───────────────────────────────────────────────────────────

/// Result entry for top-K matching
const TopKEntry = struct {
    distance: u32,
    index: i32,
};

/// Sorted top-K list (ascending by distance)
const TopKList = struct {
    distances: [K]u32,
    indices: [K]i32,

    fn init() TopKList {
        var result: TopKList = undefined;
        @memset(&result.distances, std.math.maxInt(u32));
        @memset(&result.indices, -1);
        return result;
    }

    /// Insert a candidate if it's better than the current worst.
    /// Maintains sorted order (ascending by distance).
    fn insert(self: *TopKList, distance: u32, index: i32) void {
        // Early exit if worse than current K-th best
        if (distance >= self.distances[K - 1]) return;

        // Insert at K-1 position
        self.distances[K - 1] = distance;
        self.indices[K - 1] = index;

        // Bubble up to maintain sorted order
        var k: usize = K - 1;
        while (k > 0) : (k -= 1) {
            if (self.distances[k] < self.distances[k - 1]) {
                // Swap distance
                const td = self.distances[k - 1];
                self.distances[k - 1] = self.distances[k];
                self.distances[k] = td;

                // Swap index
                const ti = self.indices[k - 1];
                self.indices[k - 1] = self.indices[k];
                self.indices[k] = ti;
            } else {
                break;
            }
        }
    }

    /// Merge another top-K list into this one
    fn merge(self: *TopKList, other: *const TopKList) void {
        for (other.distances, other.indices) |d, i| {
            if (i < 0) continue;
            self.insert(d, i);
        }
    }

    /// Get the best (smallest distance) entry
    fn best(self: *const TopKList) TopKEntry {
        return .{
            .distance = self.distances[0],
            .index = self.indices[0],
        };
    }
};

// ── Coarse-to-fine batch matching ──────────────────────────────────────────

/// Coarse-to-fine batch matching.
///
/// Algorithm:
///   1. Coarse stage: compare only the first coarse_len bytes (smallest-scale
///      gray feature) against all n_pages. Collect top-K candidates per target.
///   2. Fine stage: compare full feat_len bytes against only those K candidates.
///
/// This reduces memory traffic from n_pages × feat_len to
/// (n_pages × coarse_len) + (K × feat_len) per target.
///
/// Arguments:
///   - lib: flattened library features [n_pages][feat_len]
///   - targets: flattened target features [num_targets][feat_len]
///   - n_pages: number of pages in library
///   - feat_len: feature vector length
///   - coarse_len: number of bytes to use for coarse matching
///   - allocator: memory allocator
///
/// Returns: slice of length num_targets with best matching page index per target
pub fn matchBatchCoarse(
    allocator: std.mem.Allocator,
    lib: []const u8,
    targets: []const u8,
    n_pages: u32,
    num_targets: u32,
    feat_len: u32,
    coarse_len: u32,
) ![]i32 {
    if (num_targets == 0 or n_pages == 0) {
        return try allocator.alloc(i32, 0);
    }

    const lib_slice_len: usize = @as(usize, n_pages) * feat_len;
    const target_slice_len: usize = @as(usize, num_targets) * feat_len;

    // Validate input lengths
    if (lib.len < lib_slice_len) return error.InvalidLibraryLength;
    if (targets.len < target_slice_len) return error.InvalidTargetLength;

    // If only one page, all targets match to page 0
    if (n_pages == 1) {
        const results = try allocator.alloc(i32, num_targets);
        @memset(results, 0);
        return results;
    }

    // Determine if fine stage is needed
    const actual_coarse_len = if (coarse_len >= feat_len) feat_len else coarse_len;
    const fine_needed = coarse_len < feat_len;

    // Allocate result array
    const results = try allocator.alloc(i32, num_targets);
    errdefer allocator.free(results);

    // Coarse stage: collect top-K candidates per target
    const top_k = try allocator.alloc(TopKList, num_targets);
    defer allocator.free(top_k);

    for (top_k) |*tk| {
        tk.* = TopKList.init();
    }

    // ── Threading setup ──
    const num_threads = if (g_match_threads > 0) g_match_threads else @max(1, std.Thread.getCpuCount() catch 1);
    const use_threads = num_threads > 1 and num_targets > num_threads;
    const chunk_size = if (use_threads) (num_targets + num_threads - 1) / num_threads else 0;

    // ── Coarse stage: parallel over target chunks ──
    if (use_threads) {
        var handles = try allocator.alloc(std.Thread, num_threads);
        defer {
            var t: u32 = 0;
            while (t < num_threads) : (t += 1) {
                handles[t].join();
            }
            allocator.free(handles);
        }

        var t: u32 = 0;
        while (t < num_threads) : (t += 1) {
            const start: u32 = @intCast(t * chunk_size);
            const end: u32 = @intCast(@min(start + chunk_size, num_targets));
            if (start >= num_targets) break;

            const ctx = try allocator.create(CoarseCtx);
            ctx.* = .{
                .lib = lib,
                .targets = targets,
                .top_k = top_k,
                .n_pages = n_pages,
                .num_targets = num_targets,
                .feat_len = feat_len,
                .actual_coarse_len = actual_coarse_len,
                .start_target = start,
                .end_target = end,
            };

            handles[t] = try std.Thread.spawn(.{}, processCoarseChunk, .{ctx});
        }
    } else {
        var page_idx: u32 = 0;
        while (page_idx < n_pages) : (page_idx += 1) {
            const page_offset = @as(usize, page_idx) * feat_len;
            const page = lib[page_offset..][0..feat_len];

            var target_idx: u32 = 0;
            while (target_idx < num_targets) : (target_idx += 1) {
                const target_offset = @as(usize, target_idx) * feat_len;
                const target = targets[target_offset..][0..feat_len];

                const d = featureL1(page[0..actual_coarse_len], target[0..actual_coarse_len]);

                top_k[target_idx].insert(d, @intCast(page_idx));
            }
        }
    }

    // ── Fine stage: parallel over target chunks ──
    if (fine_needed) {
        if (use_threads) {
            var handles = try allocator.alloc(std.Thread, num_threads);
            defer {
                var t: u32 = 0;
                while (t < num_threads) : (t += 1) {
                    handles[t].join();
                }
                allocator.free(handles);
            }

            var t: u32 = 0;
            while (t < num_threads) : (t += 1) {
                const start: u32 = @intCast(t * chunk_size);
                const end: u32 = @intCast(@min(start + chunk_size, num_targets));
                if (start >= num_targets) break;

                const ctx = try allocator.create(FineCtx);
                ctx.* = .{
                    .lib = lib,
                    .targets = targets,
                    .top_k = top_k,
                    .results = results,
                    .num_targets = num_targets,
                    .feat_len = feat_len,
                    .start_target = start,
                    .end_target = end,
                };

                handles[t] = try std.Thread.spawn(.{}, processFineChunk, .{ctx});
            }
        } else {
            var target_idx: u32 = 0;
            while (target_idx < num_targets) : (target_idx += 1) {
                var best_d: u32 = std.math.maxInt(u32);
                var best_i: i32 = -1;

                const target_offset = @as(usize, target_idx) * feat_len;
                const target = targets[target_offset..][0..feat_len];

                for (top_k[target_idx].indices, top_k[target_idx].distances) |candidate_idx, _| {
                    if (candidate_idx < 0) break;

                    const candidate_offset = @as(usize, @intCast(candidate_idx)) * feat_len;
                    const candidate = lib[candidate_offset..][0..feat_len];

                    const d = featureL1Bounded(candidate, target, best_d);
                    if (d < best_d) {
                        best_d = d;
                        best_i = candidate_idx;
                    }
                }

                if (best_i == -1) {
                    best_i = top_k[target_idx].indices[0];
                }
                results[target_idx] = best_i;
            }
        }
    } else {
        // Coarse stage already used the full feature vector
        for (top_k, 0..) |tk, idx| {
            results[idx] = tk.indices[0];
        }
    }

    return results;
}

/// Simple batch matching (backward compatible with C API).
/// Uses full feature vector for matching (coarse_len = feat_len).
pub fn matchBatch(
    allocator: std.mem.Allocator,
    lib: []const u8,
    targets: []const u8,
    n_pages: u32,
    num_targets: u32,
    feat_len: u32,
) ![]i32 {
    return matchBatchCoarse(
        allocator,
        lib,
        targets,
        n_pages,
        num_targets,
        feat_len,
        feat_len, // coarse_len = full for backward compat
    );
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "featureL1 - identical vectors" {
    const a = [_]u8{ 10, 20, 30, 40, 50 };
    const b = [_]u8{ 10, 20, 30, 40, 50 };
    const dist = featureL1(&a, &b);
    try std.testing.expectEqual(@as(u32, 0), dist);
}

test "featureL1 - simple difference" {
    const a = [_]u8{ 10, 20, 30 };
    const b = [_]u8{ 15, 25, 35 };
    const dist = featureL1(&a, &b);
    // |10-15| + |20-25| + |30-35| = 5 + 5 + 5 = 15
    try std.testing.expectEqual(@as(u32, 15), dist);
}

test "featureL1 - mixed directions" {
    const a = [_]u8{ 10, 50, 30 };
    const b = [_]u8{ 20, 40, 30 };
    const dist = featureL1(&a, &b);
    // |10-20| + |50-40| + |30-30| = 10 + 10 + 0 = 20
    try std.testing.expectEqual(@as(u32, 20), dist);
}

test "featureL1Bounded - early termination" {
    const a = [_]u8{ 10, 20, 30, 40, 50 };
    const b = [_]u8{ 15, 25, 35, 45, 55 };
    // Each element differs by 5, so partial sums: 5, 10, 15, 20, 25
    const dist = featureL1Bounded(&a, &b, 12);
    // Should terminate early when dist > 12 (after 3rd element: 15 > 12)
    try std.testing.expect(dist > 12);
}

test "featureL1Bounded - completes if under bound" {
    const a = [_]u8{ 10, 20, 30 };
    const b = [_]u8{ 12, 22, 32 };
    // Each element differs by 2, total = 6
    const dist = featureL1Bounded(&a, &b, 100);
    try std.testing.expectEqual(@as(u32, 6), dist);
}

test "TopKList - basic insert and ordering" {
    var list = TopKList.init();
    list.insert(50, 0);
    list.insert(30, 1);
    list.insert(10, 2);
    list.insert(40, 3);

    // Should be sorted: 10, 30, 40, 50, ...
    try std.testing.expectEqual(@as(u32, 10), list.distances[0]);
    try std.testing.expectEqual(@as(i32, 2), list.indices[0]);
    try std.testing.expectEqual(@as(u32, 30), list.distances[1]);
    try std.testing.expectEqual(@as(i32, 1), list.indices[1]);
    try std.testing.expectEqual(@as(u32, 40), list.distances[2]);
    try std.testing.expectEqual(@as(i32, 3), list.indices[2]);
    try std.testing.expectEqual(@as(u32, 50), list.distances[3]);
    try std.testing.expectEqual(@as(i32, 0), list.indices[3]);
}

test "TopKList - caps at K entries" {
    var list = TopKList.init();
    // Insert more than K entries
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        list.insert(i * 10, @intCast(i));
    }

    // Should have the K smallest: 0, 10, 20, ..., (K-1)*10
    i = 0;
    while (i < K) : (i += 1) {
        try std.testing.expectEqual(i * 10, list.distances[i]);
    }
}

test "TopKList - merge" {
    var list1 = TopKList.init();
    list1.insert(100, 0);
    list1.insert(50, 1);

    var list2 = TopKList.init();
    list2.insert(30, 2);
    list2.insert(80, 3);

    list1.merge(&list2);

    // Should have: 30, 50, 80, 100
    try std.testing.expectEqual(@as(u32, 30), list1.distances[0]);
    try std.testing.expectEqual(@as(u32, 50), list1.distances[1]);
    try std.testing.expectEqual(@as(u32, 80), list1.distances[2]);
    try std.testing.expectEqual(@as(u32, 100), list1.distances[3]);
}

test "matchBatchCoarse - single page" {
    const allocator = std.testing.allocator;

    // 1 page, 3 features per page, 2 targets
    const lib = [_]u8{
        10, 20, 30, // page 0
    };
    const targets = [_]u8{
        10, 20, 30, // target 0 (identical to page 0)
        15, 25, 35, // target 1 (differs by 5 each)
    };

    const results = try matchBatchCoarse(
        allocator,
        &lib,
        &targets,
        1, // n_pages
        2, // num_targets
        3, // feat_len
        3, // coarse_len
    );
    defer allocator.free(results);

    // Both targets should match page 0
    try std.testing.expectEqual(@as(i32, 0), results[0]);
    try std.testing.expectEqual(@as(i32, 0), results[1]);
}

test "matchBatchCoarse - multiple pages" {
    const allocator = std.testing.allocator;

    // 3 pages, 4 features per page, 1 target
    const lib = [_]u8{
        10, 20, 30, 40, // page 0
        15, 25, 35, 45, // page 1
        50, 60, 70, 80, // page 2
    };
    const targets = [_]u8{
        15, 25, 35, 45, // target 0 (identical to page 1)
    };

    const results = try matchBatchCoarse(
        allocator,
        &lib,
        &targets,
        3, // n_pages
        1, // num_targets
        4, // feat_len
        4, // coarse_len
    );
    defer allocator.free(results);

    // Target should match page 1
    try std.testing.expectEqual(@as(i32, 1), results[0]);
}

test "matchBatchCoarse - coarse to fine" {
    const allocator = std.testing.allocator;

    // 4 pages, 8 features per page, 1 target
    // Page 0: very close on coarse features (first 2 bytes), far on fine
    // Page 1: far on coarse features, very close on fine (full 8 bytes)
    const lib = [_]u8{
        11, 21, 50, 50, 50, 50, 50, 50, // page 0: coarse dist 2, fine dist 754
        20, 30, 102, 152, 202, 182, 222, 192, // page 1: coarse dist 16, fine dist 16
        50, 60, 70, 80, 90, 100, 110, 120, // page 2: far away
        100, 200, 150, 50, 180, 120, 90, 60, // page 3: far away
    };
    const targets = [_]u8{
        12, 22, 102, 152, 202, 182, 222, 192, // target
    };

    // coarse_len=2 means only first 2 bytes for coarse stage
    const results = try matchBatchCoarse(
        allocator,
        &lib,
        &targets,
        4, // n_pages
        1, // num_targets
        8, // feat_len
        2, // coarse_len (only first 2 bytes for coarse)
    );
    defer allocator.free(results);

    // Fine stage should pick page 1 (closest on full features)
    try std.testing.expectEqual(@as(i32, 1), results[0]);
}

test "matchBatch - backward compatible" {
    const allocator = std.testing.allocator;

    const lib = [_]u8{
        10, 20, 30,
        40, 50, 60,
    };
    const targets = [_]u8{
        11, 21, 31, // closest to page 0
    };

    const results = try matchBatch(
        allocator,
        &lib,
        &targets,
        2, // n_pages
        1, // num_targets
        3, // feat_len
    );
    defer allocator.free(results);

    try std.testing.expectEqual(@as(i32, 0), results[0]);
}

test "matchBatchCoarse - empty inputs" {
    const allocator = std.testing.allocator;

    const results = try matchBatchCoarse(
        allocator,
        &.{},
        &.{},
        0,
        0,
        0,
        0,
    );
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "setThreads and getThreads" {
    setThreads(4);
    try std.testing.expectEqual(@as(u32, 4), getThreads());

    setThreads(0);
    try std.testing.expectEqual(@as(u32, 4), getThreads()); // should not change

    setThreads(8);
    try std.testing.expectEqual(@as(u32, 8), getThreads());
}

test "featureL1 - large values" {
    const a = [_]u8{255, 255, 255};
    const b = [_]u8{0, 0, 0};
    const dist = featureL1(&a, &b);
    // 255 + 255 + 255 = 765
    try std.testing.expectEqual(@as(u32, 765), dist);
}

test "featureL1 - no overflow on reasonable input" {
    // 1000 bytes each differing by 255 = 255000, well within u32
    var a: [1000]u8 = undefined;
    var b: [1000]u8 = undefined;
    @memset(&a, 255);
    @memset(&b, 0);

    const dist = featureL1(&a, &b);
    // 1000 * 255 = 255000
    try std.testing.expectEqual(@as(u32, 255000), dist);
}
