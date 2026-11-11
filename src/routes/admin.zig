const std = @import("std");
const auth = @import("auth");
const config = @import("config");
const db = @import("db_pool");
const domain = @import("domain");
const applications = @import("application_service");
const account = @import("account_routes");
const http = @import("http_server");
const response = http.response;

pub const Router = struct {
    allocator: std.mem.Allocator,
    auth_service: auth.AuthService,
    application_service: applications.ApplicationService,

    pub fn init(allocator: std.mem.Allocator, pool: *db.Pool, configuration: *const config.Config) !Router {
        return .{ .allocator = allocator, .auth_service = auth.AuthService.init(allocator, pool, configuration), .application_service = try applications.ApplicationService.init(allocator, pool) };
    }
    pub fn deinit(self: *Router) void {
        self.application_service.deinit();
    }
};

pub fn register(server: *http.Server, router: *Router) !void {
    try server.route(.GET, "/api/v1/admin/applications", router, handle);
    try server.route(.GET, "/api/v1/admin/users/:id", router, handle);
    try server.routeJson(.POST, "/api/v1/admin/applications/:id/approve", router, handle);
    try server.routeJson(.POST, "/api/v1/admin/applications/:id/reject", router, handle);
    try server.routeJson(.PATCH, "/api/v1/admin/users/:id", router, handle);
}

fn handle(context: *anyopaque, request: http.Request, request_id: []const u8) !response.Response {
    const router: *Router = @ptrCast(@alignCast(context));
    return dispatch(router, request) catch |err| errorResponse(router.allocator, err, request_id);
}

fn dispatch(router: *Router, request: http.Request) !response.Response {
    const authentication = auth.Request{ .session_token = try account.sessionToken(request.cookie), .csrf_token = request.csrf_token };
    const actor = try router.auth_service.authenticate(authentication);
    const action: domain.types.Action = if (request.method == .PATCH) .edit_user_identity else .view_moderation_queue;
    if (!domain.application.canPerform(actor.role, action)) return error.InsufficientRole;
    const query_start = std.mem.indexOfScalar(u8, request.target, '?') orelse request.target.len;
    const path = request.target[0..query_start];
    if (request.method != .GET) {
        try router.auth_service.requireCsrf(authentication, actor);
        if (query_start != request.target.len) return error.InvalidQuery;
        const mutation: applications.AdminMutation = if (request.method == .PATCH) .edit else if (std.mem.endsWith(u8, path, "/approve")) .approve else .reject;
        const start = if (mutation == .edit) "/api/v1/admin/users/".len else "/api/v1/admin/applications/".len;
        const end = if (mutation == .edit) path.len else std.mem.lastIndexOfScalar(u8, path, '/').?;
        const id = try parseId(path[start..end]);
        try router.application_service.mutateAdmin(&router.auth_service, actor, authentication, id, mutation, request.body);
        var result = try response.Response.init(router.allocator, 204, "");
        errdefer result.deinit();
        try result.addHeader("Cache-Control", "no-store");
        return result;
    }
    var arena = std.heap.ArenaAllocator.init(router.allocator);
    defer arena.deinit();
    const body = if (std.mem.eql(u8, path, "/api/v1/admin/applications"))
        try router.application_service.queue(try parseQuery(arena.allocator(), request.target))
    else blk: {
        if (query_start != request.target.len) return error.InvalidQuery;
        break :blk try router.application_service.card(try parseId(path["/api/v1/admin/users/".len..]));
    };
    defer router.allocator.free(body);
    var result = try response.Response.init(router.allocator, 200, body);
    errdefer result.deinit();
    try result.addHeader("Content-Type", "application/json");
    try result.addHeader("Cache-Control", "no-store");
    return result;
}

fn parseId(raw: []const u8) !i64 {
    if (raw.len == 0 or raw[0] == '0') return error.InvalidId;
    for (raw) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidId;
    return std.fmt.parseInt(i64, raw, 10) catch error.InvalidId;
}

fn parseQuery(allocator: std.mem.Allocator, target: []const u8) !applications.Queue {
    var result = applications.Queue{};
    const start = std.mem.indexOfScalar(u8, target, '?') orelse return result;
    if (start + 1 == target.len) return error.InvalidQuery;
    var fields = std.mem.splitScalar(u8, target[start + 1 ..], '&');
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    while (fields.next()) |field| {
        const equal = std.mem.indexOfScalar(u8, field, '=') orelse return error.InvalidQuery;
        const key = try decode(allocator, field[0..equal]);
        const value = try decode(allocator, field[equal + 1 ..]);
        if (seen.contains(key)) return error.InvalidQuery;
        try seen.put(key, {});
        if (std.mem.eql(u8, key, "status")) {
            result.status = std.meta.stringToEnum(domain.types.ApplicationStatus, value) orelse return error.InvalidQuery;
        } else if (std.mem.eql(u8, key, "query")) {
            const trimmed = std.mem.trim(u8, value, " \t\r\n");
            if (trimmed.len == 0 or trimmed.len > 100) return error.InvalidQuery;
            result.query = trimmed;
        } else if (std.mem.eql(u8, key, "limit")) {
            if (value.len == 0) return error.InvalidQuery;
            for (value) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidQuery;
            result.limit = std.fmt.parseInt(u8, value, 10) catch return error.InvalidQuery;
            if (result.limit < 1 or result.limit > 100) return error.InvalidQuery;
        } else if (std.mem.eql(u8, key, "cursor")) {
            if (value.len != 32) return error.InvalidQuery;
            var bytes: [16]u8 = undefined;
            _ = std.fmt.hexToBytes(&bytes, value) catch return error.InvalidQuery;
            result.cursor_time = std.mem.readInt(i64, bytes[0..8], .big);
            result.cursor_id = std.mem.readInt(i64, bytes[8..16], .big);
            if (result.cursor_time.? < 0 or result.cursor_time.? > 253402300799999999 or result.cursor_id.? <= 0) return error.InvalidQuery;
        } else return error.InvalidQuery;
    }
    return result;
}

fn decode(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const output = try allocator.alloc(u8, raw.len);
    var written: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '%') {
            if (i + 2 >= raw.len) return error.InvalidQuery;
            const high = std.fmt.charToDigit(raw[i + 1], 16) catch return error.InvalidQuery;
            const low = std.fmt.charToDigit(raw[i + 2], 16) catch return error.InvalidQuery;
            output[written] = @intCast(high * 16 + low);
            i += 2;
        } else output[written] = if (raw[i] == '+') ' ' else raw[i];
        written += 1;
    }
    const value = output[0..written];
    if (!std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidQuery;
    return value;
}

fn errorResponse(allocator: std.mem.Allocator, err: anyerror, request_id: []const u8) !response.Response {
    const Error = struct { status: u16, code: []const u8 };
    const mapped: Error = switch (err) {
        error.SessionNotFound => .{ .status = 401, .code = "authentication_required" },
        error.InsufficientRole => .{ .status = 403, .code = "insufficient_role" },
        error.AccountReadOnly => .{ .status = 403, .code = "account_read_only" },
        error.CsrfTokenRequired => .{ .status = 403, .code = "csrf_token_required" },
        error.CsrfTokenInvalid => .{ .status = 403, .code = "csrf_token_invalid" },
        error.UserNotFound => .{ .status = 404, .code = "user_not_found" },
        error.ApplicationNotFound => .{ .status = 404, .code = "application_not_found" },
        error.ApplicationNotPending => .{ .status = 409, .code = "application_not_pending" },
        error.InvalidStatusTransition => .{ .status = 409, .code = "invalid_status_transition" },
        error.DiscordIdInUse => .{ .status = 409, .code = "discord_id_in_use" },
        error.NicknameUnavailable => .{ .status = 409, .code = "nickname_unavailable" },
        error.InvalidJson => .{ .status = 400, .code = "invalid_json" },
        error.InvalidQuery => .{ .status = 422, .code = "invalid_query" },
        error.InvalidId => .{ .status = 422, .code = "invalid_id" },
        error.EmptyPatch => .{ .status = 422, .code = "empty_patch" },
        error.InvalidPatchField => .{ .status = 422, .code = "invalid_patch_field" },
        error.InvalidMinecraftNickname => .{ .status = 422, .code = "invalid_minecraft_nickname" },
        error.InvalidDiscordId => .{ .status = 422, .code = "invalid_discord_id" },
        error.InvalidClientType => .{ .status = 422, .code = "invalid_client_type" },
        error.InvalidStatus => .{ .status = 422, .code = "invalid_status" },
        error.InvalidReason => .{ .status = 422, .code = "invalid_reason" },
        error.ReasonRequired => .{ .status = 422, .code = "reason_required" },
        error.ReasonTooLong => .{ .status = 422, .code = "reason_too_long" },
        error.InvalidRejectionKind => .{ .status = 422, .code = "invalid_rejection_kind" },
        else => .{ .status = 500, .code = "internal_error" },
    };
    return http.errors.errorResponse(allocator, mapped.status, mapped.code, "Admin request could not be completed.", request_id);
}
