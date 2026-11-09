const std = @import("std");
const db = @import("db_pool");

pub const TestDatabase = struct {
    allocator: std.mem.Allocator,
    admin_pool: db.Pool,
    pool: db.Pool,
    name: []u8,
    database_url: []u8,

    pub fn create(allocator: std.mem.Allocator, admin_database_url: []const u8) !TestDatabase {
        if (!std.mem.startsWith(u8, admin_database_url, "postgresql://") and !std.mem.startsWith(u8, admin_database_url, "postgres://")) {
            return error.InvalidTestDatabaseUrl;
        }

        const now: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
        const name = try std.fmt.allocPrint(allocator, "mine_api_test_{x}", .{now});
        errdefer allocator.free(name);

        const database_url = try databaseUrl(allocator, admin_database_url, name);
        errdefer allocator.free(database_url);

        var admin_pool = try db.Pool.open(allocator, admin_database_url);
        errdefer admin_pool.close();

        const create_sql = try std.fmt.allocPrint(allocator, "CREATE DATABASE {s}", .{name});
        defer allocator.free(create_sql);
        var create_result = try admin_pool.query(create_sql, &.{});
        create_result.deinit();
        errdefer dropDatabase(allocator, &admin_pool, name);

        const pool = try db.Pool.open(allocator, database_url);
        return .{
            .allocator = allocator,
            .admin_pool = admin_pool,
            .pool = pool,
            .name = name,
            .database_url = database_url,
        };
    }

    pub fn deinit(self: *TestDatabase) void {
        self.pool.close();
        dropDatabase(self.allocator, &self.admin_pool, self.name);
        self.admin_pool.close();
        self.allocator.free(self.name);
        self.allocator.free(self.database_url);
    }
};

fn dropDatabase(allocator: std.mem.Allocator, admin_pool: *db.Pool, name: []const u8) void {
    const drop_sql = std.fmt.allocPrint(allocator, "DROP DATABASE IF EXISTS {s}", .{name}) catch return;
    defer allocator.free(drop_sql);
    var drop_result = admin_pool.query(drop_sql, &.{}) catch return;
    drop_result.deinit();
}

fn databaseUrl(allocator: std.mem.Allocator, admin_database_url: []const u8, database_name: []const u8) ![]u8 {
    const query_start = std.mem.indexOfScalar(u8, admin_database_url, '?') orelse admin_database_url.len;
    const base_url = admin_database_url[0..query_start];
    const database_start = (std.mem.lastIndexOfScalar(u8, base_url, '/') orelse return error.InvalidTestDatabaseUrl) + 1;
    if (database_start == base_url.len) return error.InvalidTestDatabaseUrl;

    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
        admin_database_url[0..database_start],
        database_name,
        admin_database_url[query_start..],
    });
}
