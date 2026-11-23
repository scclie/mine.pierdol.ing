const std = @import("std");
const db = @import("db_pool");

pub const Repository = struct {
    pool: *db.Pool,

    pub fn init(pool: *db.Pool) Repository {
        return .{ .pool = pool };
    }

    // the existing dispatcher serializes use of the shared pool connection
    pub fn creditActiveMinutes(self: *Repository, user_ids: []const i64) !void {
        if (user_ids.len == 0) return error.InvalidBatch;
        if (user_ids.len > 100) return error.BatchTooLarge;
        var storage: [100]i64 = undefined;
        const ordered = storage[0..user_ids.len];
        @memcpy(ordered, user_ids);
        std.mem.sort(i64, ordered, {}, std.sort.asc(i64));
        for (ordered, 0..) |id, index| {
            if (id <= 0 or (index > 0 and ordered[index - 1] == id)) return error.InvalidBatch;
        }

        var transaction = try self.pool.begin();
        var committed = false;
        defer if (!committed) transaction.rollback() catch {};

        // lock in ascending order and validate the whole batch before any DML
        for (ordered) |id| {
            var id_buffer: [20]u8 = undefined;
            const parameter = try std.fmt.bufPrint(&id_buffer, "{d}", .{id});
            var row = try transaction.query("SELECT id, active_seconds FROM users WHERE id = $1::bigint FOR UPDATE", &.{parameter});
            defer row.deinit();
            if (row.rowCount() == 0) return error.UserNotFound;
            if (row.rowCount() != 1) return error.InvalidDatabaseResult;
            if (try std.fmt.parseInt(i64, row.value(0, 0), 10) != id) return error.InvalidDatabaseResult;
            const active_seconds = try std.fmt.parseInt(i64, row.value(0, 1), 10);
            if (active_seconds < 0) return error.InvalidDatabaseResult;
            if (active_seconds > 9223372036854775747) return error.ActiveSecondsOverflow;
        }
        for (ordered) |id| {
            var id_buffer: [20]u8 = undefined;
            const parameter = try std.fmt.bufPrint(&id_buffer, "{d}", .{id});
            var row = try transaction.query("UPDATE users SET active_seconds = active_seconds + 60 WHERE id = $1::bigint RETURNING id", &.{parameter});
            defer row.deinit();
            if (row.rowCount() != 1) return error.InvalidDatabaseResult;
            if (try std.fmt.parseInt(i64, row.value(0, 0), 10) != id) return error.InvalidDatabaseResult;
        }
        try transaction.commit();
        committed = true;
    }
};
