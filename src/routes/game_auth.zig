const std = @import("std");
const config = @import("config");
const db = @import("db_pool");
const service = @import("game_auth_service");
const http = @import("http_server");
const response = http.response;

pub const Router = struct {
    allocator: std.mem.Allocator,
    configuration: *const config.Config,
    service: service.GameAuthService,

    pub fn init(allocator: std.mem.Allocator, pool: *db.Pool, configuration: *const config.Config) Router {
        return .{ .allocator = allocator, .configuration = configuration, .service = service.GameAuthService.init(allocator, pool) };
    }

    pub fn deinit(self: *Router) void {
        self.service.deinit();
    }
};

pub fn register(server: *http.Server, router: *Router) !void {
    server.setInternalAuthentication(router, authenticate);
    server.setInternalAdmission(router, admit);
    try server.route(.GET, "/internal/game-auth/v1/identity-policy", router, handle);
    try server.route(.GET, "/internal/game-auth/v1/whitelist", router, handle);
    try server.routeJson(.POST, "/internal/game-auth/v1/cracked-login", router, handle);
    try server.routeJson(.POST, "/internal/game-auth/v1/premium-verified", router, handle);
    try server.routeJson(.POST, "/internal/game-auth/v1/session-check", router, handle);
}

fn authenticate(context: *anyopaque, authorization: ?[]const u8) ?[]const u8 {
    const router: *Router = @ptrCast(@alignCast(context));
    return authenticatedServerId(router.configuration, authorization);
}

fn admit(context: *anyopaque, server_id: []const u8) !void {
    const router: *Router = @ptrCast(@alignCast(context));
    try router.service.admitServer(server_id);
}

fn failure(router: *Router, request_id: []const u8, err: anyerror) !response.Response {
    return deniedResponse(router.allocator, request_id, switch (err) {
        error.InvalidJson, error.InvalidQuery => 400,
        error.RateLimited => 429,
        else => 500,
    });
}

fn handle(context: *anyopaque, request: http.Request, request_id: []const u8) !response.Response {
    const router: *Router = @ptrCast(@alignCast(context));
    const server_id = request.authenticated_server_id orelse return deniedResponse(router.allocator, request_id, 401);
    const path = request.target[0 .. std.mem.indexOfScalar(u8, request.target, '?') orelse request.target.len];
    const body = if (std.mem.eql(u8, path, "/internal/game-auth/v1/identity-policy")) blk: {
        var name_buffer: [64]u8 = undefined;
        defer std.crypto.utils.secureZero(u8, &name_buffer);
        const name = parseNickname(request.target, &name_buffer) catch return deniedResponse(router.allocator, request_id, 400);
        router.service.admitNickname(server_id, name) catch |err| return failure(router, request_id, err);
        const payload = router.service.nicknamePolicy(name) catch |err| return failure(router, request_id, err);
        router.service.repository.audit(server_id, null, "continue", "identity_policy") catch {
            std.crypto.utils.secureZero(u8, payload);
            router.allocator.free(payload);
            return deniedResponse(router.allocator, request_id, 500);
        };
        break :blk payload;
    } else if (std.mem.eql(u8, path, "/internal/game-auth/v1/whitelist")) blk: {
        const cursor = parseCursor(request.target) catch return deniedResponse(router.allocator, request_id, 400);
        const payload = router.service.whitelist(cursor) catch return deniedResponse(router.allocator, request_id, 500);
        router.service.repository.audit(server_id, null, "continue", "whitelist_snapshot") catch {
            std.crypto.utils.secureZero(u8, payload);
            router.allocator.free(payload);
            return deniedResponse(router.allocator, request_id, 500);
        };
        break :blk payload;
    } else if (std.mem.eql(u8, path, "/internal/game-auth/v1/cracked-login")) blk: {
        if (std.mem.indexOfScalar(u8, request.target, '?') != null) return deniedResponse(router.allocator, request_id, 400);
        break :blk router.service.crackedLogin(server_id, request.body) catch |err| return failure(router, request_id, err);
    } else if (std.mem.eql(u8, path, "/internal/game-auth/v1/premium-verified")) blk: {
        if (std.mem.indexOfScalar(u8, request.target, '?') != null) return deniedResponse(router.allocator, request_id, 400);
        break :blk router.service.premiumVerified(server_id, request.body) catch |err| return failure(router, request_id, err);
    } else if (std.mem.eql(u8, path, "/internal/game-auth/v1/session-check")) blk: {
        if (std.mem.indexOfScalar(u8, request.target, '?') != null) return deniedResponse(router.allocator, request_id, 400);
        break :blk router.service.sessionCheck(server_id, request.body) catch |err| return failure(router, request_id, err);
    } else return deniedResponse(router.allocator, request_id, 404);
    defer {
        std.crypto.utils.secureZero(u8, body);
        router.allocator.free(body);
    }
    return jsonResponse(router.allocator, request_id, body);
}

fn authenticatedServerId(configuration: *const config.Config, authorization: ?[]const u8) ?[]const u8 {
    const header = authorization orelse return null;
    if (!std.mem.startsWith(u8, header, "Bearer ")) return null;
    const token = header["Bearer ".len..];
    if (token.len == 0 or token.len > 128) return null;
    var matched: ?[]const u8 = null;
    for (configuration.game_auth_credentials) |credential| {
        if (constantTimeEql(credential.secret, token)) matched = credential.server_id;
    }
    return matched;
}

fn constantTimeEql(expected: []const u8, actual: []const u8) bool {
    var difference: usize = expected.len ^ actual.len;
    if (expected.len > 128 or actual.len > 128) return false;
    for (0..128) |index| {
        const left: u8 = if (index < expected.len) expected[index] else 0;
        const right: u8 = if (index < actual.len) actual[index] else 0;
        difference |= @as(usize, left ^ right);
    }
    return difference == 0;
}

fn parseCursor(target: []const u8) !?u64 {
    const separator = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    const query = target[separator + 1 ..];
    if (query.len == 0) return error.InvalidCursor;
    var cursor: ?u64 = null;
    var values = std.mem.splitScalar(u8, query, '&');
    while (values.next()) |value| {
        const equals = std.mem.indexOfScalar(u8, value, '=') orelse return error.InvalidCursor;
        if (!std.mem.eql(u8, value[0..equals], "cursor") or cursor != null) return error.InvalidCursor;
        const number = value[equals + 1 ..];
        if (number.len == 0) return error.InvalidCursor;
        for (number) |byte| if (byte < '0' or byte > '9') return error.InvalidCursor;
        cursor = std.fmt.parseInt(u64, number, 10) catch return error.InvalidCursor;
        if (cursor.? > std.math.maxInt(i64)) return error.InvalidCursor;
    }
    return cursor;
}

fn parseNickname(target: []const u8, buffer: []u8) ![]const u8 {
    const separator = std.mem.indexOfScalar(u8, target, '?') orelse return error.InvalidQuery;
    const query = target[separator + 1 ..];
    if (!std.mem.startsWith(u8, query, "nickname=")) return error.InvalidQuery;
    const encoded = query[9..];
    var source: usize = 0;
    var count: usize = 0;
    while (source < encoded.len) : (source += 1) {
        if (count == buffer.len) return error.InvalidQuery;
        var byte = encoded[source];
        if (byte == '%') {
            if (source + 2 >= encoded.len) return error.InvalidQuery;
            byte = std.fmt.parseInt(u8, encoded[source + 1 .. source + 3], 16) catch return error.InvalidQuery;
            source += 2;
        } else if (byte == '&' or byte == '=' or byte == '#' or byte == '+') return error.InvalidQuery;
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return error.InvalidQuery;
        buffer[count] = byte;
        count += 1;
    }
    if (count < 3 or count > 16) return error.InvalidQuery;
    return buffer[0..count];
}

fn jsonResponse(allocator: std.mem.Allocator, _: []const u8, body: []const u8) !response.Response {
    var result = try response.Response.init(allocator, 200, body);
    result.sensitive_body = true;
    errdefer result.deinit();
    try result.addHeader("Content-Type", "application/json");
    try result.addHeader("Cache-Control", "no-store");
    return result;
}

fn deniedResponse(allocator: std.mem.Allocator, _: []const u8, status: u16) !response.Response {
    var result = try response.Response.init(allocator, status, "{\"outcome\":\"deny\"}");
    errdefer result.deinit();
    try result.addHeader("Content-Type", "application/json");
    try result.addHeader("Cache-Control", "no-store");
    return result;
}
