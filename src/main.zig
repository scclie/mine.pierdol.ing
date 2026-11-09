const std = @import("std");
const db = @import("db_pool");
const migrations = @import("db/migrations.zig");

pub fn main() !void {
    const database_url = std.posix.getenv("DATABASE_URL") orelse {
        try std.io.getStdErr().writer().writeAll("mine-api: configure DATABASE_URL before starting\n");
        std.process.exit(1);
    };

    var pool = try db.Pool.open(std.heap.page_allocator, database_url);
    defer pool.close();
    try migrations.apply(&pool);
}
