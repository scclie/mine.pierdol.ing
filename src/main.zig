const std = @import("std");
const db = @import("db_pool");
const domain = @import("domain");
const migrations = @import("db/migrations.zig");
const config = @import("config");

pub fn main() !void {
    var configuration = try config.Config.load(std.heap.page_allocator);
    defer configuration.deinit();

    var deny_list = try domain.password.loadDefaultDenyList(std.heap.page_allocator);
    defer deny_list.deinit();

    var pool = try db.Pool.open(std.heap.page_allocator, configuration.database_url);
    defer pool.close();
    try migrations.apply(&pool);
}
