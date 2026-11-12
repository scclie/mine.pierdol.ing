const std = @import("std");
const auth = @import("auth");
const config = @import("config");
const db = @import("db_pool");
const applications = @import("application_service");
const http = @import("http_server");
const response = http.response;

pub const Router = struct {
    allocator: std.mem.Allocator,
    auth_service: auth.AuthService,
    application_service: applications.ApplicationService,

    pub fn init(allocator: std.mem.Allocator, pool: *db.Pool, configuration: *const config.Config) !Router {
        return .{
            .allocator = allocator,
            .auth_service = auth.AuthService.init(allocator, pool, configuration),
            .application_service = try applications.ApplicationService.init(allocator, pool),
        };
    }

    pub fn deinit(self: *Router) void {
        self.application_service.deinit();
    }
};

pub fn register(server: *http.Server, router: *Router) !void {
    try server.route(.GET, "/api/v1/account", router, handle);
    try server.routeJson(.POST, "/api/v1/account/application", router, handle);
    try server.routeJson(.PATCH, "/api/v1/account/application", router, handle);
    try server.routeJson(.POST, "/api/v1/account/password", router, handle);
}

fn handle(context: *anyopaque, request: http.Request, request_id: []const u8) !response.Response {
    const router: *Router = @ptrCast(@alignCast(context));
    return dispatch(router, request) catch |err| errorResponse(router.allocator, err, request_id);
}

fn dispatch(router: *Router, request: http.Request) !response.Response {
    const authentication = auth.Request{ .session_token = try sessionToken(request.cookie), .csrf_token = request.csrf_token };
    const actor = try router.auth_service.authenticate(authentication);
    if (request.method != .GET) {
        try router.auth_service.requireCsrf(authentication, actor);
        const path = request.target[0 .. std.mem.indexOfScalar(u8, request.target, '?') orelse request.target.len];
        const mutation: applications.Mutation = if (std.mem.endsWith(u8, path, "/password")) .password else if (request.method == .PATCH) .resubmit else .create;
        try router.application_service.mutate(actor, authentication, mutation, request.body);
        if (mutation == .password) return response.Response.init(router.allocator, 204, "");
    }
    const body = try router.application_service.account(actor, authentication.session_token);
    defer {
        std.crypto.utils.secureZero(u8, body);
        router.allocator.free(body);
    }
    var result = try response.Response.init(router.allocator, if (request.method == .POST) 201 else 200, body);
    errdefer result.deinit();
    try result.addHeader("Content-Type", "application/json");
    try result.addHeader("Cache-Control", "no-store");
    return result;
}

pub fn sessionToken(cookie: ?[]const u8) ![]const u8 {
    var fields = std.mem.splitScalar(u8, cookie orelse return error.SessionNotFound, ';');
    var token: ?[]const u8 = null;
    while (fields.next()) |raw| {
        const field = std.mem.trim(u8, raw, " \t");
        const equal = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        if (!std.mem.eql(u8, field[0..equal], "mine_session")) continue;
        if (token != null) return error.SessionNotFound;
        token = field[equal + 1 ..];
    }
    const value = token orelse return error.SessionNotFound;
    if (value.len != 64) return error.SessionNotFound;
    for (value) |byte| if (!std.ascii.isHex(byte)) return error.SessionNotFound;
    return value;
}

fn errorResponse(allocator: std.mem.Allocator, err: anyerror, request_id: []const u8) !response.Response {
    const Error = struct { status: u16, code: []const u8 };
    const mapped: Error = switch (err) {
        error.SessionNotFound => .{ .status = 401, .code = "authentication_required" },
        error.CsrfTokenRequired => .{ .status = 403, .code = "csrf_token_required" },
        error.CsrfTokenInvalid => .{ .status = 403, .code = "csrf_token_invalid" },
        error.AccountReadOnly => .{ .status = 403, .code = "account_read_only" },
        error.ApplicationAlreadyExists => .{ .status = 409, .code = "application_already_exists" },
        error.ApplicationNotEditable => .{ .status = 409, .code = "application_not_editable" },
        error.PasswordNotApplicable => .{ .status = 409, .code = "password_not_applicable" },
        error.PasswordChangeNotAllowed => .{ .status = 409, .code = "password_change_not_allowed" },
        error.NicknameUnavailable => .{ .status = 409, .code = "nickname_unavailable" },
        error.NicknameImmutable => .{ .status = 409, .code = "nickname_immutable" },
        error.InvalidJson => .{ .status = 400, .code = "invalid_json" },
        error.PasswordRequiredForCracked => .{ .status = 422, .code = "password_required_for_cracked" },
        error.PasswordNotAllowedForLicensed => .{ .status = 422, .code = "password_not_allowed_for_licensed" },
        error.MinecraftNicknameRequired => .{ .status = 422, .code = "minecraft_nickname_required" },
        error.InvalidMinecraftNickname => .{ .status = 422, .code = "invalid_minecraft_nickname" },
        error.InvalidClientType => .{ .status = 422, .code = "invalid_client_type" },
        error.AboutMeRequired => .{ .status = 422, .code = "about_me_required" },
        error.InvalidAboutMe => .{ .status = 422, .code = "invalid_about_me" },
        error.AboutMeTooLong => .{ .status = 422, .code = "about_me_too_long" },
        error.DiscoverySourceRequired => .{ .status = 422, .code = "discovery_source_required" },
        error.InvalidDiscoverySource => .{ .status = 422, .code = "invalid_discovery_source" },
        error.DiscoverySourceTooLong => .{ .status = 422, .code = "discovery_source_too_long" },
        error.PasswordRequired => .{ .status = 422, .code = "password_required" },
        error.InvalidPassword => .{ .status = 422, .code = "invalid_password" },
        error.PasswordTooShort => .{ .status = 422, .code = "password_too_short" },
        error.PasswordDenied => .{ .status = 422, .code = "password_denied" },
        else => .{ .status = 500, .code = "internal_error" },
    };
    return http.errors.errorResponse(allocator, mapped.status, mapped.code, "Account request could not be completed.", request_id);
}
