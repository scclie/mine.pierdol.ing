const std = @import("std");
const config = @import("config");
const auth = @import("auth");
const discord = @import("discord");
const http = @import("http_server");
const response = http.response;
const errors = http.errors;

pub const Router = struct {
    allocator: std.mem.Allocator,
    discord_service: *discord.DiscordService,
    configuration: *const config.Config,

    pub fn init(allocator: std.mem.Allocator, discord_service: *discord.DiscordService, configuration: *const config.Config) !Router {
        return .{ .allocator = allocator, .discord_service = discord_service, .configuration = configuration };
    }

    pub fn deinit(_: *Router) void {}
};

pub fn register(server: *http.Server, router: *Router) !void {
    try server.route(.GET, "/api/v1/auth/discord", router, beginLogin);
    try server.route(.GET, "/api/v1/auth/discord/callback", router, completeCallback);
}

fn beginLogin(context: *anyopaque, request: http.Request, _: []const u8) !response.Response {
    const router: *Router = @ptrCast(@alignCast(context));
    const requested_return_path = queryValue(request.target, "return_path");
    var redirect = try router.discord_service.beginLogin(requested_return_path);
    defer redirect.deinit(router.allocator);
    var result = try response.Response.init(router.allocator, 302, "");
    errdefer result.deinit();
    try result.addSensitiveHeader("Location", redirect.location);
    return result;
}

fn completeCallback(context: *anyopaque, request: http.Request, request_id: []const u8) !response.Response {
    const router: *Router = @ptrCast(@alignCast(context));
    const raw_code = queryValue(request.target, "code") orelse return oauthStateError(router.allocator, request_id);
    const raw_state = queryValue(request.target, "state") orelse return oauthStateError(router.allocator, request_id);
    const code = try decodeQueryValue(router.allocator, raw_code);
    defer {
        @memset(code, 0);
        router.allocator.free(code);
    }
    const state = try decodeQueryValue(router.allocator, raw_state);
    defer {
        @memset(state, 0);
        router.allocator.free(state);
    }
    var completed = router.discord_service.completeCallback(code, state) catch |err| switch (err) {
        error.OauthStateInvalid => return oauthStateError(router.allocator, request_id),
        else => return errors.errorResponse(router.allocator, 502, "oauth_provider_error", "OAuth provider authentication failed.", request_id),
    };
    defer completed.deinit(router.allocator);

    const user_id = router.discord_service.upsertIdentity(completed.identity) catch return errors.errorResponse(router.allocator, 500, "internal_error", "An internal error occurred.", request_id);
    var auth_service = auth.AuthService.init(router.allocator, router.discord_service.pool, router.configuration);
    var issued = auth_service.createSession(user_id) catch return errors.errorResponse(router.allocator, 500, "internal_error", "An internal error occurred.", request_id);
    defer issued.deinit(router.allocator);

    var result = try response.redirect(router.allocator, completed.return_path);
    errdefer result.deinit();
    const secure = if (router.configuration.development_mode) "" else "; Secure";
    const cookie = try std.fmt.allocPrint(router.allocator, "mine_session={s}; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000{s}", .{ &issued.session_token, secure });
    defer {
        std.crypto.utils.secureZero(u8, cookie);
        router.allocator.free(cookie);
    }
    try result.addSensitiveHeader("Set-Cookie", cookie);
    return result;
}

fn oauthStateError(allocator: std.mem.Allocator, request_id: []const u8) !response.Response {
    return errors.errorResponse(allocator, 400, "oauth_state_invalid", "OAuth state is invalid or expired.", request_id);
}

fn queryValue(target: []const u8, name: []const u8) ?[]const u8 {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var fields = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');
    while (fields.next()) |field| {
        const equal = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        if (std.mem.eql(u8, field[0..equal], name)) return field[equal + 1 ..];
    }
    return null;
}

fn decodeQueryValue(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var output = try allocator.alloc(u8, raw.len);
    errdefer {
        @memset(output, 0);
        allocator.free(output);
    }
    var written: usize = 0;
    var index: usize = 0;
    while (index < raw.len) : (index += 1) {
        if (raw[index] == '%') {
            if (index + 2 >= raw.len) return error.InvalidQueryEncoding;
            const high = std.fmt.charToDigit(raw[index + 1], 16) catch return error.InvalidQueryEncoding;
            const low = std.fmt.charToDigit(raw[index + 2], 16) catch return error.InvalidQueryEncoding;
            output[written] = @intCast(high * 16 + low);
            written += 1;
            index += 2;
        } else {
            output[written] = if (raw[index] == '+') ' ' else raw[index];
            written += 1;
        }
    }
    return allocator.realloc(output, written);
}
