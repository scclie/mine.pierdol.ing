const std = @import("std");
const db = @import("db_pool");
const ranking = @import("ranking_repository");
const http = @import("http_server");

pub const page_size: usize = 50;
const ttl_ns: u64 = 300 * std.time.ns_per_s;
const retry_ns: u64 = 5 * std.time.ns_per_s;
const path = "/api/v1/public/ranking";

const Player = struct { rank: usize, minecraft_nickname: []const u8, active_minutes: u64, banned: bool };
const Page = struct { page: u64, page_size: usize = page_size, total_players: usize, total_pages: usize, updated_at: []const u8, players: []const Player };

pub fn parsePage(target: []const u8) !u64 {
    if (std.mem.indexOfScalar(u8, target, '#') != null) return error.InvalidQuery;
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse {
        if (!std.mem.eql(u8, target, path)) return error.InvalidQuery;
        return 1;
    };
    if (!std.mem.eql(u8, target[0..query_start], path)) return error.InvalidQuery;
    const query = target[query_start + 1 ..];
    if (query.len == 0) return 1;
    if (!std.mem.startsWith(u8, query, "page=")) return error.InvalidQuery;
    const value = query[5..];
    if (value.len == 0) return error.InvalidQuery;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidQuery;
    const page = std.fmt.parseInt(u64, value, 10) catch return error.InvalidQuery;
    if (page == 0) return error.InvalidQuery;
    return page;
}

pub fn isFresh(age_ns: u64) bool {
    return age_ns < ttl_ns;
}

pub fn remainingTtl(age_ns: u64) u64 {
    return (ttl_ns - @min(age_ns, ttl_ns)) / std.time.ns_per_s;
}

fn utcTimestamp(seconds: i64) ![20]u8 {
    if (seconds < 0) return error.InvalidTimestamp;
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
    const day = epoch.getEpochDay().calculateYearDay();
    const date = day.calculateMonthDay();
    const time = epoch.getDaySeconds();
    if (day.year > 9999) return error.InvalidTimestamp;
    var buffer: [20]u8 = undefined;
    _ = try std.fmt.bufPrint(&buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ day.year, @intFromEnum(date.month), date.day_index + @as(u8, 1), time.getHoursIntoDay(), time.getMinutesIntoHour(), time.getSecondsIntoMinute() });
    return buffer;
}

// access is serialized by server.dispatch_mutex, including the shared libpq pool
pub const Provider = struct {
    allocator: std.mem.Allocator,
    repository: ranking.Repository,
    timer: std.time.Timer,
    dataset: ?ranking.Dataset = null,
    refreshed_ns: u64 = 0,
    retry_deadline_ns: ?u64 = null,
    updated_at: [20]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, pool: *db.Pool) !Provider {
        return .{ .allocator = allocator, .repository = ranking.Repository.init(pool), .timer = try std.time.Timer.start() };
    }

    pub fn deinit(self: *Provider) void {
        if (self.dataset) |*dataset| dataset.deinit();
        self.dataset = null;
    }

    fn refresh(self: *Provider) !void {
        const now = self.timer.read();
        if (self.dataset != null and isFresh(now - self.refreshed_ns)) return;
        if (self.retry_deadline_ns) |deadline| if (now < deadline) return error.RankingUnavailable;
        if (self.dataset) |*dataset| dataset.deinit();
        self.dataset = null;
        errdefer self.retry_deadline_ns = self.timer.read() +| retry_ns;
        var dataset = try self.repository.load(self.allocator);
        errdefer dataset.deinit();
        self.updated_at = try utcTimestamp(std.time.timestamp());
        self.refreshed_ns = self.timer.read();
        self.dataset = dataset;
        self.retry_deadline_ns = null;
    }
};

pub fn register(server: *http.Server, provider: *Provider) !void {
    try server.route(.GET, path, provider, handle);
}

fn failure(provider: *Provider, status: u16, code: []const u8, message: []const u8, request_id: []const u8) !http.response.Response {
    var result = try http.errors.errorResponse(provider.allocator, status, code, message, request_id);
    errdefer result.deinit();
    try result.addHeader("Cache-Control", "no-store");
    if (status == 503) try result.addHeader("Retry-After", "5");
    return result;
}

fn handle(context: *anyopaque, request: http.Request, request_id: []const u8) !http.response.Response {
    const provider: *Provider = @ptrCast(@alignCast(context));
    const requested = parsePage(request.target) catch return failure(provider, 400, "invalid_query", "Invalid ranking query", request_id);
    provider.refresh() catch return failure(provider, 503, "ranking_unavailable", "Ranking unavailable", request_id);
    const entries = provider.dataset.?.entries;
    const total_pages = @max(1, entries.len / page_size + @intFromBool(entries.len % page_size != 0));
    const page = @min(requested, total_pages);
    const start = (@as(usize, @intCast(page)) - 1) * page_size;
    const count = @min(page_size, entries.len - start);
    var players: [page_size]Player = undefined;
    for (entries[start..][0..count], 0..) |entry, i| players[i] = .{ .rank = start + i + 1, .minecraft_nickname = entry.minecraft_nickname, .active_minutes = entry.active_minutes, .banned = entry.banned };
    const body = try std.json.stringifyAlloc(provider.allocator, Page{ .page = page, .total_players = entries.len, .total_pages = total_pages, .updated_at = &provider.updated_at, .players = players[0..count] }, .{});
    defer provider.allocator.free(body);
    var result = try http.response.Response.init(provider.allocator, 200, body);
    errdefer result.deinit();
    try result.addHeader("Content-Type", "application/json; charset=utf-8");
    var cache_control: [64]u8 = undefined;
    const max_age = remainingTtl(provider.timer.read() - provider.refreshed_ns);
    try result.addHeader("Cache-Control", try std.fmt.bufPrint(&cache_control, "public, max-age={d}, must-revalidate", .{max_age}));
    return result;
}
