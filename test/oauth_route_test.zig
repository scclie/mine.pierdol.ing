const std = @import("std");
const c = @cImport({
    @cInclude("stdlib.h");
});
const config = @import("config");
const db = @import("db_pool");
const migrations = @import("migrations");
const postgres = @import("postgres");
const http = @import("http_server");
const discord = @import("discord");
const auth_routes = @import("auth_routes");
const response = http.response;

const valid_session_key = "0123456789abcdef0123456789abcdef";

fn setEnvironment(name: [:0]const u8, value: [:0]const u8) !void {
    try std.testing.expectEqual(@as(c_int, 0), c.setenv(name.ptr, value.ptr, 1));
}

fn setValidEnvironment() !void {
    try setEnvironment("DATABASE_URL", "postgresql://unused");
    try setEnvironment("HTTP_LISTEN_ADDRESS", "127.0.0.1:8088");
    try setEnvironment("PUBLIC_ORIGIN", "http://127.0.0.1:3000");
    try setEnvironment("DISCORD_CLIENT_ID", "test-client-id");
    try setEnvironment("DISCORD_CLIENT_SECRET", "test-client-secret");
    try setEnvironment("DISCORD_REDIRECT_URI", "http://127.0.0.1:3000/api/v1/auth/discord/callback");
    try setEnvironment("SESSION_SIGNING_KEY", valid_session_key);
    try setEnvironment("ADMIN_DISCORD_IDS", "");
    try setEnvironment("MODERATOR_DISCORD_IDS", "");
    try setEnvironment("DEVELOPMENT_MODE", "true");
}

const TcpDiscordStub = struct {
    listener: std.net.Server,
    token_body: [4096]u8 = undefined,
    token_body_len: usize = 0,
    token_method: std.http.Method = .GET,
    token_path: [128]u8 = undefined,
    token_path_len: usize = 0,
    token_type: [128]u8 = undefined,
    token_type_len: usize = 0,
    identity_seen: bool = false,
    fail_token: bool = false,
    failure: ?anyerror = null,

    fn run(self: *TcpDiscordStub) void {
        self.runInner() catch |err| {
            std.debug.print("stub error: {s}\n", .{@errorName(err)});
            self.failure = err;
        };
    }

    fn runInner(self: *TcpDiscordStub) !void {
        const requests: usize = if (self.fail_token) 1 else 2;
        for (0..requests) |index| {
            const connection = try self.listener.accept();
            defer connection.stream.close();
            var buffer: [8192]u8 = undefined;
            var server = std.http.Server.init(connection, &buffer);
            var request = try server.receiveHead();
            if (index == 0) {
                self.token_method = request.head.method;
                self.token_path_len = request.head.target.len;
                @memcpy(self.token_path[0..self.token_path_len], request.head.target);
                var headers = request.iterateHeaders();
                while (headers.next()) |header| {
                    if (std.ascii.eqlIgnoreCase(header.name, "content-type")) {
                        self.token_type_len = header.value.len;
                        @memcpy(self.token_type[0..self.token_type_len], header.value);
                    }
                }
                const reader = try request.reader();
                self.token_body_len = try reader.readAll(&self.token_body);
                try request.respond(if (self.fail_token) "{}" else "{\"access_token\":\"local-token\",\"token_type\":\"Bearer\"}", .{ .status = if (self.fail_token) .bad_request else .ok, .keep_alive = false });
            } else {
                try std.testing.expectEqual(std.http.Method.GET, request.head.method);
                try std.testing.expectEqualStrings("/api/users/@me", request.head.target);
                var headers = request.iterateHeaders();
                var bearer = false;
                while (headers.next()) |header| {
                    if (std.ascii.eqlIgnoreCase(header.name, "authorization")) bearer = std.mem.eql(u8, header.value, "Bearer local-token");
                }
                try std.testing.expect(bearer);
                self.identity_seen = true;
                try request.respond("{\"id\":\"123456789012345678\",\"username\":\"test-user\",\"global_name\":\"Test User\",\"avatar\":null}", .{ .keep_alive = false });
            }
        }
    }
};

fn formValue(form: []const u8, name: []const u8) ?[]const u8 {
    var fields = std.mem.splitScalar(u8, form, '&');
    while (fields.next()) |field| {
        const equal = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        if (std.mem.eql(u8, field[0..equal], name)) return field[equal + 1 ..];
    }
    return null;
}

test "oauth_route_test production HTTP uses a local TCP Discord provider" {
    const admin_database_url = std.posix.getenv("TEST_DATABASE_URL") orelse return error.MissingTestDatabaseUrl;
    var test_database = try postgres.TestDatabase.create(std.testing.allocator, admin_database_url);
    defer test_database.deinit();
    try migrations.apply(&test_database.pool);
    try setValidEnvironment();
    var loaded_config = try config.Config.load(std.testing.allocator);
    defer loaded_config.deinit();
    for (0..2) |case| {
        var stub = TcpDiscordStub{ .listener = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{}), .fail_token = case == 1 };
        defer stub.listener.deinit();
        const thread = try std.Thread.spawn(.{}, TcpDiscordStub.run, .{&stub});
        const token_url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/api/oauth2/token", .{stub.listener.listen_address.getPort()});
        defer std.testing.allocator.free(token_url);
        const identity_url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/api/users/@me", .{stub.listener.listen_address.getPort()});
        defer std.testing.allocator.free(identity_url);
        var service = discord.DiscordService.initProductionForTest(std.testing.allocator, &test_database.pool, &loaded_config, token_url, identity_url);
        var router = try auth_routes.Router.init(std.testing.allocator, &service, &loaded_config);
        defer router.deinit();
        var server = http.Server.init(std.testing.allocator);
        defer server.deinit();
        try auth_routes.register(&server, &router);
        var login = try server.dispatch(.{ .method = .GET, .target = "/api/v1/auth/discord" });
        defer login.deinit();
        const location = login.header("Location").?;
        const challenge = queryValue(location, "code_challenge").?;
        const state = queryValue(location, "state").?;
        const target = try std.fmt.allocPrint(std.testing.allocator, "/api/v1/auth/discord/callback?code=test-code&state={s}", .{state});
        defer std.testing.allocator.free(target);
        var callback = try server.dispatch(.{ .method = .GET, .target = target, .cookie = cookiePair(&login) });
        defer callback.deinit();
        thread.join();
        if (stub.failure) |failure| return failure;
        try std.testing.expectEqual(@as(u16, if (case == 0) 302 else 502), callback.status);
        if (case == 1) {
            try expectNoSession(&callback);
            try std.testing.expect(std.mem.indexOf(u8, callback.header("Set-Cookie").?, "Max-Age=0") != null);
            const code = try errorCode(callback.body);
            defer std.testing.allocator.free(code);
            try std.testing.expectEqualStrings("oauth_provider_error", code);
        }
        try std.testing.expectEqual(std.http.Method.POST, stub.token_method);
        try std.testing.expectEqualStrings("/api/oauth2/token", stub.token_path[0..stub.token_path_len]);
        try std.testing.expectEqualStrings("application/x-www-form-urlencoded", stub.token_type[0..stub.token_type_len]);
        const form = stub.token_body[0..stub.token_body_len];
        try std.testing.expectEqualStrings("test-client-id", formValue(form, "client_id").?);
        try std.testing.expectEqualStrings("test-client-secret", formValue(form, "client_secret").?);
        try std.testing.expectEqualStrings("authorization_code", formValue(form, "grant_type").?);
        try std.testing.expectEqualStrings("test-code", formValue(form, "code").?);
        try std.testing.expectEqualStrings("http%3A%2F%2F127.0.0.1%3A3000%2Fapi%2Fv1%2Fauth%2Fdiscord%2Fcallback", formValue(form, "redirect_uri").?);
        const verifier = formValue(form, "code_verifier").?;
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(verifier, &hash, .{});
        var encoded: [43]u8 = undefined;
        try std.testing.expectEqualStrings(challenge, std.base64.url_safe_no_pad.Encoder.encode(&encoded, &hash));
        try std.testing.expectEqual(case == 0, stub.identity_seen);
    }
}

const LocalDiscordEndpoint = struct {
    token_request_seen: bool = false,
    identity_request_seen: bool = false,

    fn exchange(context: *anyopaque, code: []const u8, verifier: []const u8) ![]const u8 {
        const self: *LocalDiscordEndpoint = @ptrCast(@alignCast(context));
        try std.testing.expectEqualStrings("test-code", code);
        try std.testing.expect(verifier.len >= 43);
        self.token_request_seen = true;
        return "local-access-token";
    }

    fn identity(context: *anyopaque, access_token: []const u8) !discord.DiscordIdentity {
        const self: *LocalDiscordEndpoint = @ptrCast(@alignCast(context));
        try std.testing.expectEqualStrings("local-access-token", access_token);
        self.identity_request_seen = true;
        return .{
            .id = "123456789012345678",
            .username = "test-user",
            .global_name = "Test User",
            .avatar = null,
        };
    }
};

fn queryValue(target: []const u8, name: []const u8) ?[]const u8 {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var fields = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');
    while (fields.next()) |field| {
        const equal = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        if (std.mem.eql(u8, field[0..equal], name)) return field[equal + 1 ..];
    }
    return null;
}

fn errorCode(body: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    return try std.testing.allocator.dupe(u8, parsed.value.object.get("error").?.object.get("code").?.string);
}

fn sensitiveHeader(result: *const response.Response, name: []const u8) ?bool {
    for (result.headers.items) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.sensitive;
    }
    return null;
}

fn testJsonHandler(_: *anyopaque, _: http.Request, _: []const u8) !response.Response {
    return response.Response.init(std.testing.allocator, 204, "");
}

test "oauth_route_test JSON routes reject unsupported or unbounded request bodies" {
    var server = http.Server.init(std.testing.allocator);
    defer server.deinit();
    var context: u8 = 0;
    try server.routeJson(.POST, "/json", &context, testJsonHandler);

    var unsupported = try server.dispatch(.{ .method = .POST, .target = "/json", .content_type = "text/plain", .content_length = 2 });
    defer unsupported.deinit();
    try std.testing.expectEqual(@as(u16, 415), unsupported.status);

    var too_large = try server.dispatch(.{ .method = .POST, .target = "/json", .content_type = "application/json", .content_length = 64 * 1024 + 1 });
    defer too_large.deinit();
    try std.testing.expectEqual(@as(u16, 413), too_large.status);

    var unknown_length = try server.dispatch(.{ .method = .POST, .target = "/json", .content_type = "application/json", .content_length = null });
    defer unknown_length.deinit();
    try std.testing.expectEqual(@as(u16, 413), unknown_length.status);
}

test "oauth_route_test Discord login uses PKCE and callbacks consume one-time states before exchange" {
    const admin_database_url = std.posix.getenv("TEST_DATABASE_URL") orelse return error.MissingTestDatabaseUrl;
    var test_database = try postgres.TestDatabase.create(std.testing.allocator, admin_database_url);
    defer test_database.deinit();
    try migrations.apply(&test_database.pool);

    try setValidEnvironment();
    var loaded_config = try config.Config.load(std.testing.allocator);
    defer loaded_config.deinit();

    var local_discord = LocalDiscordEndpoint{};
    var discord_service = discord.DiscordService.init(std.testing.allocator, &test_database.pool, &loaded_config, .{
        .authorization_endpoint = "http://local-discord/authorize",
        .exchange = LocalDiscordEndpoint.exchange,
        .identity = LocalDiscordEndpoint.identity,
        .context = &local_discord,
    });
    var router = try auth_routes.Router.init(std.testing.allocator, &discord_service, &loaded_config);
    defer router.deinit();

    var server = http.Server.init(std.testing.allocator);
    defer server.deinit();
    try auth_routes.register(&server, &router);

    var login_response = try server.dispatch(.{ .method = .GET, .target = "/api/v1/auth/discord" });
    defer login_response.deinit();
    try std.testing.expectEqual(@as(u16, 302), login_response.status);
    const location = login_response.header("Location").?;
    try std.testing.expect(sensitiveHeader(&login_response, "Location").?);
    try std.testing.expect(std.mem.startsWith(u8, location, "http://local-discord/authorize?"));
    try std.testing.expectEqualStrings("code", queryValue(location, "response_type").?);
    try std.testing.expectEqualStrings("S256", queryValue(location, "code_challenge_method").?);
    const state = queryValue(location, "state").?;
    try std.testing.expect(state.len >= 43);

    var missing_response = try server.dispatch(.{ .method = .GET, .target = "/api/v1/auth/discord/callback?code=test-code" });
    defer missing_response.deinit();
    try std.testing.expectEqual(@as(u16, 400), missing_response.status);
    const missing_code = try errorCode(missing_response.body);
    defer std.testing.allocator.free(missing_code);
    try std.testing.expectEqualStrings("oauth_state_invalid", missing_code);

    const callback_target = try std.fmt.allocPrint(std.testing.allocator, "/api/v1/auth/discord/callback?code=test-code&state={s}", .{state});
    defer std.testing.allocator.free(callback_target);
    var callback_response = try server.dispatch(.{ .method = .GET, .target = callback_target, .cookie = cookiePair(&login_response) });
    defer callback_response.deinit();
    try std.testing.expectEqual(@as(u16, 302), callback_response.status);
    try std.testing.expectEqualStrings("/account", callback_response.header("Location").?);
    try std.testing.expect(!sensitiveHeader(&callback_response, "Location").?);
    try std.testing.expect(sensitiveHeader(&callback_response, "Set-Cookie").?);
    const session_cookie = callback_response.header("Set-Cookie").?;
    try std.testing.expect(std.mem.indexOf(u8, session_cookie, "Path=/") != null);
    try std.testing.expect(std.mem.indexOf(u8, session_cookie, "HttpOnly") != null);
    try std.testing.expect(std.mem.indexOf(u8, session_cookie, "SameSite=Lax") != null);
    try std.testing.expect(std.mem.indexOf(u8, session_cookie, "Max-Age=2592000") != null);
    try std.testing.expect(local_discord.token_request_seen);
    try std.testing.expect(local_discord.identity_request_seen);

    var reused_response = try server.dispatch(.{ .method = .GET, .target = callback_target, .cookie = cookiePair(&login_response) });
    defer reused_response.deinit();
    try std.testing.expectEqual(@as(u16, 400), reused_response.status);
    const reused_code = try errorCode(reused_response.body);
    defer std.testing.allocator.free(reused_code);
    try std.testing.expectEqualStrings("oauth_state_invalid", reused_code);

    var expired_login = try server.dispatch(.{ .method = .GET, .target = "/api/v1/auth/discord" });
    defer expired_login.deinit();
    var expired_insert = try test_database.pool.query(
        "UPDATE oauth_states SET expires_at = now() - INTERVAL '1 second'",
        &.{},
    );
    expired_insert.deinit();
    const expired_target = try std.fmt.allocPrint(std.testing.allocator, "/api/v1/auth/discord/callback?code=test-code&state={s}", .{queryValue(expired_login.header("Location").?, "state").?});
    defer std.testing.allocator.free(expired_target);
    local_discord.token_request_seen = false;
    var expired_response = try server.dispatch(.{ .method = .GET, .target = expired_target, .cookie = cookiePair(&expired_login) });
    defer expired_response.deinit();
    try std.testing.expectEqual(@as(u16, 400), expired_response.status);
    const expired_code = try errorCode(expired_response.body);
    defer std.testing.allocator.free(expired_code);
    try std.testing.expectEqualStrings("oauth_state_invalid", expired_code);
    try expectNoSession(&expired_response);
    try std.testing.expect(!local_discord.token_request_seen);
    _ = db;
}

fn cookiePair(result: *const response.Response) []const u8 {
    const header = result.header("Set-Cookie").?;
    return header[0..std.mem.indexOfScalar(u8, header, ';').?];
}

fn expectNoSession(result: *const response.Response) !void {
    for (result.headers.items) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "Set-Cookie"))
            try std.testing.expect(!std.mem.startsWith(u8, header.value, "mine_session="));
    }
}

test "oauth_route_test independent browsers cannot swap login sessions and binding cookies are secure" {
    var database = try postgres.TestDatabase.create(std.testing.allocator, std.posix.getenv("TEST_DATABASE_URL") orelse return error.MissingTestDatabaseUrl);
    defer database.deinit();
    try migrations.apply(&database.pool);
    try setValidEnvironment();
    var loaded = try config.Config.load(std.testing.allocator);
    defer loaded.deinit();
    var endpoint = LocalDiscordEndpoint{};
    var service = discord.DiscordService.init(std.testing.allocator, &database.pool, &loaded, .{
        .authorization_endpoint = "http://local-discord/authorize",
        .exchange = LocalDiscordEndpoint.exchange,
        .identity = LocalDiscordEndpoint.identity,
        .context = &endpoint,
    });
    var router = try auth_routes.Router.init(std.testing.allocator, &service, &loaded);
    defer router.deinit();
    var server = http.Server.init(std.testing.allocator);
    defer server.deinit();
    try auth_routes.register(&server, &router);
    for ([_]bool{ true, false }) |development| {
        loaded.development_mode = development;
        var a = try server.dispatch(.{ .method = .GET, .target = "/api/v1/auth/discord" });
        defer a.deinit();
        var b = try server.dispatch(.{ .method = .GET, .target = "/api/v1/auth/discord" });
        defer b.deinit();
        const target = try std.fmt.allocPrint(std.testing.allocator, "/api/v1/auth/discord/callback?code=test-code&state={s}", .{queryValue(a.header("Location").?, "state").?});
        defer std.testing.allocator.free(target);
        endpoint.token_request_seen = false;
        var missing = try server.dispatch(.{ .method = .GET, .target = target, .cookie = "mine_session=" ++ "a" ** 64 });
        defer missing.deinit();
        try std.testing.expectEqual(@as(u16, 400), missing.status);
        try expectNoSession(&missing);
        try std.testing.expect(!endpoint.token_request_seen);
        for ([_]*response.Response{ &a, &b }) |login| {
            try std.testing.expect(login.header("Set-Cookie") != null);
            const cookie = login.header("Set-Cookie").?;
            try std.testing.expect(sensitiveHeader(login, "Set-Cookie").?);
            for ([_][]const u8{ "; Path=/", "; HttpOnly", "; SameSite=Lax", "; Max-Age=600" }) |attribute|
                try std.testing.expect(std.mem.indexOf(u8, cookie, attribute) != null);
            try std.testing.expectEqual(!development, std.mem.indexOf(u8, cookie, "; Secure") != null);
            try std.testing.expect(std.mem.indexOf(u8, cookie, "Domain=") == null);
            try std.testing.expect(std.mem.startsWith(u8, cookie, if (development) "mine_oauth=" else "__Host-mine_oauth="));
            const pair = cookiePair(login);
            const secret = pair[std.mem.indexOfScalar(u8, pair, '=').? + 1 ..];
            try std.testing.expectEqual(@as(usize, 43), secret.len);
            try std.testing.expect(std.mem.indexOf(u8, login.header("Location").?, secret) == null);
        }
        try std.testing.expect(!std.mem.eql(u8, cookiePair(&a), cookiePair(&b)));
        const foreign_cookie = try std.fmt.allocPrint(std.testing.allocator, "{s}; mine_session={s}", .{ cookiePair(&b), "b" ** 64 });
        defer std.testing.allocator.free(foreign_cookie);
        const duplicate_cookie = try std.fmt.allocPrint(std.testing.allocator, "{s}; {s}", .{ cookiePair(&a), cookiePair(&a) });
        defer std.testing.allocator.free(duplicate_cookie);
        for ([_][]const u8{ foreign_cookie, duplicate_cookie, "mine_oauth=malformed" }) |cookie| {
            var rejected = try server.dispatch(.{ .method = .GET, .target = target, .cookie = cookie });
            defer rejected.deinit();
            try std.testing.expectEqual(@as(u16, 400), rejected.status);
            try expectNoSession(&rejected);
            try std.testing.expect(!endpoint.token_request_seen);
        }
        var valid = try server.dispatch(.{ .method = .GET, .target = target, .cookie = cookiePair(&a) });
        defer valid.deinit();
        try std.testing.expectEqual(@as(u16, 302), valid.status);
        try std.testing.expect(std.mem.startsWith(u8, valid.header("Set-Cookie").?, "mine_session="));
        var expired_binding = false;
        for (valid.headers.items) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "Set-Cookie") and !std.mem.startsWith(u8, header.value, "mine_session=")) {
                expired_binding = std.mem.indexOf(u8, header.value, "Max-Age=0") != null;
                try std.testing.expect(header.sensitive);
                try std.testing.expectEqual(!development, std.mem.indexOf(u8, header.value, "; Secure") != null);
            }
        }
        try std.testing.expect(expired_binding);
        endpoint.token_request_seen = false;
        var replay = try server.dispatch(.{ .method = .GET, .target = target, .cookie = cookiePair(&a) });
        defer replay.deinit();
        try std.testing.expectEqual(@as(u16, 400), replay.status);
        try expectNoSession(&replay);
        try std.testing.expect(!endpoint.token_request_seen);
    }
}
