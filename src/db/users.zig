const std = @import("std");
const db = @import("db_pool");

pub const ActiveSession = struct {
    user_id: i64,
    discord_id: []u8,
    csrf_token_hash: [32]u8,

    pub fn deinit(self: *ActiveSession, allocator: std.mem.Allocator) void {
        allocator.free(self.discord_id);
    }
};

pub const UserRepository = struct {
    pool: *db.Pool,

    pub fn init(pool: *db.Pool) UserRepository {
        return .{ .pool = pool };
    }

    pub fn findActiveSession(self: *UserRepository, allocator: std.mem.Allocator, token_hash: []const u8) !ActiveSession {
        var result = try self.pool.query(
            "SELECT web_sessions.user_id, users.discord_id, encode(web_sessions.csrf_token_hash, 'hex') FROM web_sessions JOIN users ON users.id = web_sessions.user_id WHERE web_sessions.token_hash = $1::bytea AND web_sessions.revoked_at IS NULL AND web_sessions.expires_at > now()",
            &.{token_hash},
        );
        defer result.deinit();
        if (result.rowCount() != 1) return error.SessionNotFound;

        var csrf_token_hash: [32]u8 = undefined;
        try decodeHex(result.value(0, 2), &csrf_token_hash);
        return .{
            .user_id = try std.fmt.parseInt(i64, result.value(0, 0), 10),
            .discord_id = try allocator.dupe(u8, result.value(0, 1)),
            .csrf_token_hash = csrf_token_hash,
        };
    }

    pub fn createSession(self: *UserRepository, user_id: i64, session_id: []const u8, token_hash: []const u8, csrf_token_hash: []const u8) !void {
        var user_id_buffer: [20]u8 = undefined;
        const user_id_parameter = try std.fmt.bufPrint(&user_id_buffer, "{d}", .{user_id});
        var result = try self.pool.query(
            "INSERT INTO web_sessions (id, user_id, token_hash, csrf_token_hash, expires_at) VALUES ($1::uuid, $2, $3::bytea, $4::bytea, now() + INTERVAL '30 days')",
            &.{ session_id, user_id_parameter, token_hash, csrf_token_hash },
        );
        result.deinit();
    }

    pub fn revokeSessions(self: *UserRepository, user_id: i64) !void {
        var user_id_buffer: [20]u8 = undefined;
        const user_id_parameter = try std.fmt.bufPrint(&user_id_buffer, "{d}", .{user_id});
        var transaction = try self.pool.begin();
        errdefer transaction.rollback() catch {};
        try revokeSessionsInTransaction(&transaction, user_id_parameter);
        try transaction.commit();
    }
};

pub fn revokeSessionsInTransaction(transaction: *db.Transaction, user_id: []const u8) !void {
    var result = try transaction.query("UPDATE web_sessions SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL", &.{user_id});
    result.deinit();
}

fn decodeHex(value: []const u8, destination: *[32]u8) !void {
    if (value.len != destination.len * 2) return error.InvalidSessionHash;
    for (destination, 0..) |*byte, index| {
        const high = std.fmt.charToDigit(value[index * 2], 16) catch return error.InvalidSessionHash;
        const low = std.fmt.charToDigit(value[index * 2 + 1], 16) catch return error.InvalidSessionHash;
        byte.* = @as(u8, @intCast(high * 16 + low));
    }
}
