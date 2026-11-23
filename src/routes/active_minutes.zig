const std = @import("std");
const db = @import("db_pool");
const http = @import("http_server");
const playtime = @import("playtime_service");
const response = http.response;

pub const Router = struct {
    allocator: std.mem.Allocator,
    pool: *db.Pool,

    pub fn init(allocator: std.mem.Allocator, pool: *db.Pool) Router {
        return .{ .allocator = allocator, .pool = pool };
    }
};

pub fn register(server: *http.Server, router: *Router) !void {
    try server.routeJson(.POST, "/internal/game-auth/v1/active-minutes", router, handle);
}

fn handle(context: *anyopaque, request: http.Request, _: []const u8) !response.Response {
    const router: *Router = @ptrCast(@alignCast(context));
    if (request.authenticated_server_id == null) return http.internalResponse(router.allocator, 401);
    if (std.mem.indexOfScalar(u8, request.target, '?') != null) return http.internalResponse(router.allocator, 400);
    playtime.creditActiveMinutes(router.allocator, router.pool, request.body) catch |err| return http.internalResponse(router.allocator, switch (err) {
        error.InvalidBatch => 400,
        error.BatchTooLarge => 413,
        error.UserNotFound => 422,
        error.ActiveSecondsOverflow => 409,
        else => 500,
    });
    var result = try response.Response.init(router.allocator, 204, "");
    errdefer result.deinit();
    try result.addHeader("Cache-Control", "no-store");
    return result;
}
