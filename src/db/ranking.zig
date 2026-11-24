const std = @import("std");
const db = @import("db_pool");

pub const max_active_minutes: u64 = 9007199254740991;

pub fn publicMinutes(seconds: i64) !u64 {
    if (seconds < 0) return error.InvalidRankingSeconds;
    const minutes: u64 = @intCast(@divTrunc(seconds, 60));
    if (minutes > max_active_minutes) return error.RankingMinutesOutOfRange;
    return minutes;
}

pub const Entry = struct {
    minecraft_nickname: []const u8,
    active_minutes: u64,
    banned: bool,
};

pub const Dataset = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const Entry,

    pub fn deinit(self: *Dataset) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Repository = struct {
    pool: *db.Pool,

    pub fn init(pool: *db.Pool) Repository {
        return .{ .pool = pool };
    }

    pub fn load(self: *Repository, allocator: std.mem.Allocator) !Dataset {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        var result = try self.pool.query(
            \\SELECT a.minecraft_nickname, u.active_seconds, (a.status = 'banned') AS banned
            \\FROM applications AS a
            \\JOIN users AS u ON u.id = a.user_id
            \\WHERE a.status IN ('approved', 'banned')
            \\  AND a.minecraft_nickname IS NOT NULL
            \\  AND btrim(a.minecraft_nickname) <> ''
            \\ORDER BY (a.status = 'banned') ASC, u.active_seconds DESC,
            \\         a.minecraft_nickname COLLATE "C" ASC, u.id ASC
        , &.{});
        defer result.deinit();
        const entries = try arena.allocator().alloc(Entry, result.rowCount());
        for (entries, 0..) |*entry, i| {
            const raw_seconds = result.value(i, 1);
            if (raw_seconds.len == 0) return error.InvalidRankingSeconds;
            for (raw_seconds) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidRankingSeconds;
            const seconds = try std.fmt.parseInt(i64, raw_seconds, 10);
            const banned = result.value(i, 2);
            entry.* = .{
                .minecraft_nickname = try arena.allocator().dupe(u8, result.value(i, 0)),
                .active_minutes = try publicMinutes(seconds),
                .banned = if (std.mem.eql(u8, banned, "t")) true else if (std.mem.eql(u8, banned, "f")) false else return error.InvalidRankingBan,
            };
        }
        return .{ .arena = arena, .entries = entries };
    }
};
