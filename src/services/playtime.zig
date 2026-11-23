const std = @import("std");
const db = @import("db_pool");
const repository = @import("playtime_repository");

pub fn creditActiveMinutes(allocator: std.mem.Allocator, pool: *db.Pool, body: []const u8) !void {
    if (body.len > 4096) return error.BatchTooLarge;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const batch = parseBatch(arena.allocator(), body) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.BatchTooLarge => error.BatchTooLarge,
        else => error.InvalidBatch,
    };
    var repo = repository.Repository.init(pool);
    try repo.creditActiveMinutes(batch.ids[0..batch.count]);
}

const Batch = struct { ids: [100]i64 = undefined, count: usize = 0 };

// use the established std.json token parser (as in mojang.auditKeys)
fn parseBatch(allocator: std.mem.Allocator, body: []const u8) !Batch {
    var scanner = std.json.Scanner.initCompleteInput(allocator, body);
    defer scanner.deinit();
    if (try scanner.next() != .object_begin) return error.InvalidBatch;
    const key = try scanner.nextAllocMax(allocator, .alloc_always, 4096);
    if (key != .allocated_string or !std.mem.eql(u8, key.allocated_string, "user_ids")) return error.InvalidBatch;
    if (try scanner.next() != .array_begin) return error.InvalidBatch;
    var batch = Batch{};
    while (true) {
        const token = try scanner.nextAllocMax(allocator, .alloc_always, 4096);
        if (token == .array_end) break;
        if (batch.count == batch.ids.len) return error.BatchTooLarge;
        const number = switch (token) {
            .number => |value| value,
            .allocated_number => |value| value,
            else => return error.InvalidBatch,
        };
        // do not permit coercion from strings
        if (number.len == 0) return error.InvalidBatch;
        for (number) |byte| if (byte < '0' or byte > '9') return error.InvalidBatch;
        const id = std.fmt.parseInt(i64, number, 10) catch return error.InvalidBatch;
        if (id <= 0) return error.InvalidBatch;
        for (batch.ids[0..batch.count]) |previous| if (previous == id) return error.InvalidBatch;
        batch.ids[batch.count] = id;
        batch.count += 1;
    }
    if (batch.count == 0) return error.InvalidBatch;
    if (try scanner.nextAllocMax(allocator, .alloc_always, 4096) != .object_end) return error.InvalidBatch;
    if (try scanner.next() != .end_of_document) return error.InvalidBatch;
    return batch;
}
