const std = @import("std");
const c = @cImport({
    @cInclude("stdlib.h");
});
const config = @import("config");
const auth = @import("auth");
const migrations = @import("migrations");
const postgres = @import("postgres");
const http = @import("http_server");
const discord = @import("discord");
const auth_routes = @import("auth_routes");
const domain = @import("domain");

const cracked = "{\"minecraft_nickname\":\" Example_Name \",\"client_type\":\"cracked\",\"about_me\":\" I build rail systems. \",\"discovery_source\":\" Friend \",\"password\":\"blue-harbor-falcon-2026\"}";
const licensed = "{\"minecraft_nickname\":\"Licensed_Name\",\"client_type\":\"licensed\",\"about_me\":\"I build.\",\"discovery_source\":\"Friend\"}";
const retry_licensed = "{\"minecraft_nickname\":\" Example_Name \",\"client_type\":\"licensed\",\"about_me\":\"I build.\",\"discovery_source\":\"Friend\"}";
const replacement = "{\"password\":\"blue-harbor-falcon-2027\"}";

const Fixture = struct {
    database: postgres.TestDatabase,
    loaded: config.Config,
    provider: discord.DiscordService,
    router: auth_routes.Router,
    server: http.Server,
    issued: auth.IssuedSession,
    cookie: []u8,
    context: u8 = 0,

    fn init(self: *Fixture) !void {
        self.database = try postgres.TestDatabase.create(std.testing.allocator, std.posix.getenv("TEST_DATABASE_URL") orelse return error.MissingTestDatabaseUrl);
        errdefer self.database.deinit();
        try migrations.apply(&self.database.pool);
        self.loaded = try configuration();
        errdefer self.loaded.deinit();
        self.provider = discord.DiscordService.init(std.testing.allocator, &self.database.pool, &self.loaded, .{
            .authorization_endpoint = "http://unused",
            .context = &self.context,
            .exchange = unusedExchange,
            .identity = unusedIdentity,
        });
        self.router = try auth_routes.Router.init(std.testing.allocator, &self.provider, &self.loaded);
        errdefer self.router.deinit();
        self.server = http.Server.init(std.testing.allocator);
        errdefer self.server.deinit();
        try auth_routes.register(&self.server, &self.router);
        try self.sql("INSERT INTO users (discord_id, discord_username, discord_global_name) VALUES ('123456789012345678', 'test-user', 'Test User')");
        var service = auth.AuthService.init(std.testing.allocator, &self.database.pool, &self.loaded);
        self.issued = try service.createSession(1);
        self.cookie = try std.fmt.allocPrint(std.testing.allocator, "other=value; mine_session={s}", .{self.issued.session_token});
    }

    fn deinit(self: *Fixture) void {
        @memset(self.cookie, 0);
        std.testing.allocator.free(self.cookie);
        self.issued.deinit(std.testing.allocator);
        self.server.deinit();
        self.router.deinit();
        self.loaded.deinit();
        self.database.deinit();
    }

    fn sql(self: *Fixture, query: []const u8) !void {
        var result = try self.database.pool.query(query, &.{});
        result.deinit();
    }

    fn expectSql(self: *Fixture, query: []const u8, expected: []const u8) !void {
        var result = try self.database.pool.query(query, &.{});
        defer result.deinit();
        try std.testing.expectEqualStrings(expected, result.value(0, 0));
    }

    fn get(self: *Fixture) !http.response.Response {
        return self.server.dispatch(.{ .method = .GET, .target = "/api/v1/account", .cookie = self.cookie });
    }

    fn csrf(self: *Fixture) ![64]u8 {
        var result = try self.get();
        defer result.deinit();
        try std.testing.expectEqual(@as(u16, 200), result.status);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result.body, .{});
        defer parsed.deinit();
        var token: [64]u8 = undefined;
        const value = parsed.value.object.get("csrf_token").?.string;
        try std.testing.expectEqual(@as(usize, 64), value.len);
        @memcpy(&token, value);
        return token;
    }

    fn mutate(self: *Fixture, method: std.http.Method, path: []const u8, body: []const u8, token: ?[]const u8) !http.response.Response {
        return self.server.dispatch(.{ .method = method, .target = path, .cookie = self.cookie, .csrf_token = token, .body = body, .content_type = "application/json", .content_length = body.len });
    }

    fn create(self: *Fixture, body: []const u8) !void {
        const token = try self.csrf();
        var result = try self.mutate(.POST, "/api/v1/account/application", body, &token);
        defer result.deinit();
        try std.testing.expectEqual(@as(u16, 201), result.status);
        try expectPending(result.body);
    }

    fn actions(self: *Fixture, submit: bool, resubmit: bool, password: bool) !void {
        var result = try self.get();
        defer result.deinit();
        try std.testing.expectEqual(@as(u16, 200), result.status);
        try noSecrets(result.body);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result.body, .{});
        defer parsed.deinit();
        const object = parsed.value.object;
        try std.testing.expectEqual(@as(usize, 4), object.count());
        const user = object.get("user").?.object;
        try std.testing.expectEqual(@as(usize, 5), user.count());
        try std.testing.expectEqual(@as(i64, 1), user.get("id").?.integer);
        try std.testing.expectEqualStrings("test-user", user.get("discord_username").?.string);
        try std.testing.expectEqualStrings("Test User", user.get("display_name").?.string);
        const app = object.get("application").?;
        if (app != .null) try std.testing.expectEqual(@as(usize, 4), app.object.count());
        const allowed = object.get("actions").?.object;
        try std.testing.expectEqual(submit, allowed.get("can_submit").?.bool);
        try std.testing.expectEqual(resubmit, allowed.get("can_resubmit").?.bool);
        try std.testing.expectEqual(password, allowed.get("can_change_password").?.bool);
    }

    fn audits(self: *Fixture, count: []const u8) !void {
        try self.expectSql("SELECT count(*) FROM audit_log", count);
        try self.expectSql("SELECT count(*) FROM audit_log WHERE actor_user_id IS DISTINCT FROM 1 OR subject_user_id <> 1 OR old_value IS NOT NULL OR new_value IS NOT NULL OR reason IS NOT NULL", "0");
    }
};

fn noSecrets(body: []const u8) !void {
    for ([_][]const u8{ "password_hash", "argon2", "blue-harbor", "csrf_token_hash", "token_hash", "test-client-secret", "changed_at" }) |secret| try std.testing.expect(std.mem.indexOf(u8, body, secret) == null);
}

fn expectPending(body: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const application = parsed.value.object.get("application").?.object;
    try std.testing.expectEqualStrings("pending", application.get("status").?.string);
    try std.testing.expect(application.get("decision_reason").? == .null);
    try noSecrets(body);
}

fn configuration() !config.Config {
    const values = .{
        .{ "DATABASE_URL", "postgresql://unused" },
        .{ "HTTP_LISTEN_ADDRESS", "127.0.0.1:8088" },
        .{ "PUBLIC_ORIGIN", "http://127.0.0.1:3000" },
        .{ "DISCORD_CLIENT_ID", "test-client-id" },
        .{ "DISCORD_CLIENT_SECRET", "test-client-secret" },
        .{ "DISCORD_REDIRECT_URI", "http://127.0.0.1:3000/api/v1/auth/discord/callback" },
        .{ "SESSION_SIGNING_KEY", "0123456789abcdef0123456789abcdef" },
        .{ "ADMIN_DISCORD_IDS", "123456789012345678" },
        .{ "MODERATOR_DISCORD_IDS", "223456789012345678" },
        .{ "DEVELOPMENT_MODE", "true" },
    };
    inline for (values) |pair| try std.testing.expectEqual(@as(c_int, 0), c.setenv(pair[0], pair[1], 1));
    return config.Config.load(std.testing.allocator);
}

fn unusedExchange(_: *anyopaque, _: []const u8, _: []const u8) ![]const u8 {
    return error.UnexpectedProviderCall;
}
fn unusedIdentity(_: *anyopaque, _: []const u8) !discord.DiscordIdentity {
    return error.UnexpectedProviderCall;
}

fn expectError(result: *const http.response.Response, status: u16, code: []const u8) !void {
    try std.testing.expectEqual(status, result.status);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result.body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(code, parsed.value.object.get("error").?.object.get("code").?.string);
    try std.testing.expect(result.header("X-Request-ID") != null);
}

test "logout_route_test revokes only current session and expires the actual cookie in both security modes" {
    for ([_]bool{ true, false }) |development| {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        f.loaded.development_mode = development;
        var service = auth.AuthService.init(std.testing.allocator, &f.database.pool, &f.loaded);
        var other = try service.createSession(1);
        defer other.deinit(std.testing.allocator);
        try f.sql("INSERT INTO users (discord_id, discord_username) VALUES ('999999999999999999', 'Other user')");
        var unrelated = try service.createSession(2);
        defer unrelated.deinit(std.testing.allocator);
        var token = try f.csrf();
        defer @memset(&token, 0);
        // never let untrusted selectors determine which session or user to revoke.
        const body = try std.fmt.allocPrint(std.testing.allocator, "{{\"user_id\":2,\"session_token\":\"{s}\"}}", .{other.session_token});
        defer {
            @memset(body, 0);
            std.testing.allocator.free(body);
        }
        var result = try f.mutate(.POST, "/api/v1/auth/logout?user_id=2", body, &token);
        defer result.deinit();
        try std.testing.expectEqual(@as(u16, 204), result.status);
        try std.testing.expectEqualStrings("", result.body);
        try std.testing.expectEqualStrings(if (development)
            "mine_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"
        else
            "mine_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0; Secure", result.header("Set-Cookie").?);
        for (result.headers.items) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "Set-Cookie")) try std.testing.expect(header.sensitive);
            try std.testing.expect(std.mem.indexOf(u8, header.value, &f.issued.session_token) == null);
            try std.testing.expect(std.mem.indexOf(u8, header.value, &token) == null);
        }
        var replay = try f.get();
        defer replay.deinit();
        try expectError(&replay, 401, "authentication_required");
        var repeated = try f.mutate(.POST, "/api/v1/auth/logout", "{}", &token);
        defer repeated.deinit();
        try expectError(&repeated, 401, "authentication_required");
        _ = try service.authenticate(.{ .session_token = &other.session_token, .csrf_token = null });
        _ = try service.authenticate(.{ .session_token = &unrelated.session_token, .csrf_token = null });
        try f.expectSql("SELECT count(*) FROM web_sessions WHERE revoked_at IS NOT NULL", "1");
        try f.expectSql("SELECT count(*) FROM web_sessions WHERE revoked_at IS NULL", "2");
    }
}

test "logout_route_test requires a valid unambiguous authenticated session" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const duplicate = try std.fmt.allocPrint(std.testing.allocator, "{s}; mine_session={s}", .{ f.cookie, f.issued.session_token });
    defer {
        @memset(duplicate, 0);
        std.testing.allocator.free(duplicate);
    }
    for ([_]?[]const u8{ null, "mine_session=forged", "mine_session=" ++ "0" ** 64, duplicate }) |cookie| {
        var result = try f.server.dispatch(.{ .method = .POST, .target = "/api/v1/auth/logout", .cookie = cookie, .csrf_token = &f.issued.csrf_token, .body = "{}", .content_type = "application/json", .content_length = 2 });
        defer result.deinit();
        try expectError(&result, 401, "authentication_required");
        try std.testing.expect(result.header("Set-Cookie") == null);
    }
    try f.expectSql("SELECT count(*) FROM web_sessions WHERE revoked_at IS NOT NULL", "0");
}

test "logout_route_test missing invalid and other-session CSRF cannot revoke sessions" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var service = auth.AuthService.init(std.testing.allocator, &f.database.pool, &f.loaded);
    var other = try service.createSession(1);
    defer other.deinit(std.testing.allocator);
    for ([_]?[]const u8{ null, "wrong-token", &other.csrf_token }, [_][]const u8{ "csrf_token_required", "csrf_token_invalid", "csrf_token_invalid" }) |token, code| {
        var result = try f.mutate(.POST, "/api/v1/auth/logout", "{}", token);
        defer result.deinit();
        try expectError(&result, 403, code);
        try std.testing.expect(result.header("Set-Cookie") == null);
        try noSecrets(result.body);
    }
    try f.expectSql("SELECT count(*) FROM web_sessions WHERE revoked_at IS NOT NULL", "0");
    _ = try service.authenticate(.{ .session_token = &f.issued.session_token, .csrf_token = null });
    _ = try service.authenticate(.{ .session_token = &other.session_token, .csrf_token = null });
}

test "logout_route_test expired sessions cannot logout and GET cannot mutate" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var get = try f.server.dispatch(.{ .method = .GET, .target = "/api/v1/auth/logout", .cookie = f.cookie, .csrf_token = &f.issued.csrf_token });
    defer get.deinit();
    try expectError(&get, 405, "method_not_allowed");
    try f.sql("UPDATE web_sessions SET expires_at = now() - INTERVAL '1 second'");
    var expired = try f.mutate(.POST, "/api/v1/auth/logout", "{}", &f.issued.csrf_token);
    defer expired.deinit();
    try expectError(&expired, 401, "authentication_required");
    try f.expectSql("SELECT count(*) FROM web_sessions WHERE revoked_at IS NOT NULL", "0");
}

test "logout_route_test enforces JSON media type and bounds before revocation" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var media = try f.server.dispatch(.{ .method = .POST, .target = "/api/v1/auth/logout", .cookie = f.cookie, .csrf_token = &f.issued.csrf_token, .content_type = "text/plain", .content_length = 2 });
    defer media.deinit();
    try expectError(&media, 415, "unsupported_media_type");
    var oversized = try f.server.dispatch(.{ .method = .POST, .target = "/api/v1/auth/logout", .cookie = f.cookie, .csrf_token = &f.issued.csrf_token, .content_type = "application/json", .content_length = 65537 });
    defer oversized.deinit();
    try expectError(&oversized, 413, "request_body_too_large");
    try f.expectSql("SELECT count(*) FROM web_sessions WHERE revoked_at IS NOT NULL", "0");
}

test "account_routes_test unauthenticated application creation requires server-side authentication" {
    var database = try postgres.TestDatabase.create(std.testing.allocator, std.posix.getenv("TEST_DATABASE_URL") orelse return error.MissingTestDatabaseUrl);
    defer database.deinit();
    try migrations.apply(&database.pool);
    var loaded = try configuration();
    defer loaded.deinit();
    var context: u8 = 0;
    var provider = discord.DiscordService.init(std.testing.allocator, &database.pool, &loaded, .{
        .authorization_endpoint = "http://unused",
        .context = &context,
        .exchange = unusedExchange,
        .identity = unusedIdentity,
    });
    var router = try auth_routes.Router.init(std.testing.allocator, &provider, &loaded);
    defer router.deinit();
    var server = http.Server.init(std.testing.allocator);
    defer server.deinit();
    try auth_routes.register(&server, &router);
    var result = try server.dispatch(.{ .method = .POST, .target = "/api/v1/account/application", .content_type = "application/json", .content_length = 2 });
    defer result.deinit();
    try expectError(&result, 401, "authentication_required");
}

test "account_routes_test create validates client password rules fields and JSON without leaking secrets" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.actions(true, false, false);
    const cases = [_]struct { body: []const u8, status: u16 = 422, code: []const u8 }{
        .{ .body = "{\"minecraft_nickname\":\"Example_Name\",\"client_type\":\"cracked\",\"about_me\":\"Build\",\"discovery_source\":\"Friend\"}", .code = "password_required_for_cracked" },
        .{ .body = "{\"minecraft_nickname\":\"Example_Name\",\"client_type\":\"licensed\",\"about_me\":\"Build\",\"discovery_source\":\"Friend\",\"password\":\"blue-harbor-falcon-2026\"}", .code = "password_not_allowed_for_licensed" },
        .{ .body = "{\"minecraft_nickname\":\"bad-name\",\"client_type\":\"licensed\",\"about_me\":\"Build\",\"discovery_source\":\"Friend\"}", .code = "invalid_minecraft_nickname" },
        .{ .body = "{\"minecraft_nickname\":\"Example_Name\",\"client_type\":\"other\",\"about_me\":\"Build\",\"discovery_source\":\"Friend\"}", .code = "invalid_client_type" },
        .{ .body = "{\"minecraft_nickname\":\"Example_Name\",\"client_type\":\"licensed\",\"about_me\":\"  \",\"discovery_source\":\"Friend\"}", .code = "about_me_required" },
        .{ .body = "{\"minecraft_nickname\":\"Example_Name\",\"client_type\":\"licensed\",\"about_me\":42,\"discovery_source\":\"Friend\"}", .code = "invalid_about_me" },
        .{ .body = "{\"minecraft_nickname\":\"Example_Name\",\"client_type\":\"licensed\",\"about_me\":\"Build\",\"discovery_source\":\" \"]}", .status = 400, .code = "invalid_json" },
        .{ .body = "{\"minecraft_nickname\":\"Example_Name\",\"client_type\":\"licensed\",\"about_me\":\"Build\",\"discovery_source\":\" \"}", .code = "discovery_source_required" },
        .{ .body = "{\"minecraft_nickname\":\"Example_Name\",\"client_type\":\"cracked\",\"about_me\":\"Build\",\"discovery_source\":\"Friend\",\"password\":\"short\"}", .code = "password_too_short" },
        .{ .body = "{\"minecraft_nickname\":\"Example_Name\",\"client_type\":\"cracked\",\"about_me\":\"Build\",\"discovery_source\":\"Friend\",\"password\":\"correcthorsebatterystaple\"}", .code = "password_denied" },
        .{ .body = "{\"password\":\"blue-harbor-falcon-2026\"", .status = 400, .code = "invalid_json" },
        .{ .body = "[]", .status = 400, .code = "invalid_json" },
    };
    for (cases) |case| {
        const token = try f.csrf();
        var result = try f.mutate(.POST, "/api/v1/account/application", case.body, &token);
        defer result.deinit();
        try expectError(&result, case.status, case.code);
        try noSecrets(result.body);
        try f.audits("0");
    }
    for ([_]struct { field: []const u8, length: usize, code: []const u8 }{
        .{ .field = "about_me", .length = 2002, .code = "about_me_too_long" },
        .{ .field = "discovery_source", .length = 302, .code = "discovery_source_too_long" },
    }) |case| {
        const value = try std.testing.allocator.alloc(u8, case.length);
        defer std.testing.allocator.free(value);
        for (0..case.length / 2) |i| @memcpy(value[i * 2 ..][0..2], "é");
        const body = try std.fmt.allocPrint(std.testing.allocator, "{{\"minecraft_nickname\":\"Example_Name\",\"client_type\":\"licensed\",\"about_me\":\"{s}\",\"discovery_source\":\"{s}\"}}", .{ if (std.mem.eql(u8, case.field, "about_me")) value else "Build", if (std.mem.eql(u8, case.field, "discovery_source")) value else "Friend" });
        defer std.testing.allocator.free(body);
        const token = try f.csrf();
        var result = try f.mutate(.POST, "/api/v1/account/application", body, &token);
        defer result.deinit();
        try expectError(&result, 422, case.code);
    }
}

test "account_routes_test cracked create retry and password changes persist once with one transactional audit each" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.create(cracked);
    try f.audits("1");
    try f.expectSql("SELECT count(*) FROM audit_log WHERE action = 'application_created'", "1");
    try f.expectSql("SELECT minecraft_nickname || ':' || minecraft_nickname_normalized || ':' || about_me || ':' || discovery_source FROM applications", "Example_Name:example_name:I build rail systems.:Friend");
    try f.actions(false, false, false);
    const pending_token = try f.csrf();
    var pending = try f.mutate(.PATCH, "/api/v1/account/application", cracked, &pending_token);
    defer pending.deinit();
    try expectError(&pending, 409, "application_not_editable");
    var duplicate = try f.mutate(.POST, "/api/v1/account/application", cracked, &pending_token);
    defer duplicate.deinit();
    try expectError(&duplicate, 409, "application_already_exists");
    try f.sql("UPDATE applications SET status = 'rejected_retryable', decision_reason = 'Try again', decided_at = now(), decided_by_user_id = 1, submitted_at = now() - INTERVAL '1 day'");
    try f.actions(false, true, false);
    const retry_token = try f.csrf();
    var retried = try f.mutate(.PATCH, "/api/v1/account/application", retry_licensed, &retry_token);
    defer retried.deinit();
    try std.testing.expectEqual(@as(u16, 200), retried.status);
    try expectPending(retried.body);
    try f.audits("2");
    try f.expectSql("SELECT count(*) FROM audit_log WHERE action = 'application_resubmitted'", "1");
    try f.expectSql("SELECT minecraft_nickname || ':' || client_type || ':' || about_me FROM applications", "Example_Name:licensed:I build.");
    try f.expectSql("SELECT (decision_reason IS NULL AND decided_at IS NULL AND decided_by_user_id IS NULL AND submitted_at > now() - INTERVAL '1 minute')::text FROM applications", "true");
    try f.expectSql("SELECT count(*) FROM password_credentials", "0");
    try f.sql("UPDATE applications SET status = 'rejected_retryable', decision_reason = 'Try cracked'");
    const cracked_token = try f.csrf();
    var re_cracked = try f.mutate(.PATCH, "/api/v1/account/application", cracked, &cracked_token);
    defer re_cracked.deinit();
    try std.testing.expectEqual(@as(u16, 200), re_cracked.status);
    try f.audits("3");
    try f.sql("UPDATE applications SET status = 'approved', decision_reason = NULL");
    try f.actions(false, false, true);
    const password_token = try f.csrf();
    var changed = try f.mutate(.POST, "/api/v1/account/password", replacement, &password_token);
    defer changed.deinit();
    try std.testing.expectEqual(@as(u16, 204), changed.status);
    try std.testing.expectEqualStrings("", changed.body);
    try f.audits("4");
    try f.expectSql("SELECT count(*) FROM audit_log WHERE action = 'password_changed'", "1");
    var credential = try f.database.pool.query("SELECT password_hash FROM password_credentials", &.{});
    defer credential.deinit();
    try std.testing.expect(try domain.password.verifyPassword(credential.value(0, 0), "blue-harbor-falcon-2027"));
    try std.testing.expect(!try domain.password.verifyPassword(credential.value(0, 0), "blue-harbor-falcon-2026"));
    var replay = try f.mutate(.POST, "/api/v1/account/password", replacement, &password_token);
    defer replay.deinit();
    try expectError(&replay, 403, "csrf_token_invalid");
    try f.audits("4");
}

test "account_routes_test all roles honor read-only states and licensed password restrictions" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.create(licensed);
    try f.sql("UPDATE applications SET status = 'approved'");
    try f.actions(false, false, false);
    const token = try f.csrf();
    var not_applicable = try f.mutate(.POST, "/api/v1/account/password", replacement, &token);
    defer not_applicable.deinit();
    try expectError(&not_applicable, 409, "password_not_applicable");
    for ([_][]const u8{ "123456789012345678", "223456789012345678", "323456789012345678" }, [_][]const u8{ "administrator", "moderator", "player" }) |id, role| {
        var updated = try f.database.pool.query("UPDATE users SET discord_id = $1", &.{id});
        updated.deinit();
        var account = try f.get();
        defer account.deinit();
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, account.body, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(role, parsed.value.object.get("user").?.object.get("role").?.string);
        for ([_][]const u8{ "banned", "rejected_final" }) |status| {
            var blocked = try f.database.pool.query("UPDATE applications SET status = $1::application_status, decision_reason = 'Read only'", &.{status});
            blocked.deinit();
            try f.actions(false, false, false);
            for ([_]std.http.Method{ .POST, .PATCH, .POST }, [_][]const u8{ "/api/v1/account/application", "/api/v1/account/application", "/api/v1/account/password" }) |method, path| {
                const csrf_token = try f.csrf();
                var result = try f.mutate(method, path, if (std.mem.endsWith(u8, path, "password")) replacement else licensed, &csrf_token);
                defer result.deinit();
                try expectError(&result, 403, "account_read_only");
            }
        }
    }
    try f.audits("1");
}

test "account_routes_test every mutation validates CSRF and JSON bounds and server-side session expiry" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    for ([_]std.http.Method{ .POST, .PATCH, .POST }, [_][]const u8{ "/api/v1/account/application", "/api/v1/account/application", "/api/v1/account/password" }) |method, path| {
        var missing = try f.mutate(method, path, cracked, null);
        defer missing.deinit();
        try expectError(&missing, 403, "csrf_token_required");
        var wrong = try f.mutate(method, path, cracked, "wrong-token");
        defer wrong.deinit();
        try expectError(&wrong, 403, "csrf_token_invalid");
        var media = try f.server.dispatch(.{ .method = method, .target = path, .cookie = f.cookie, .body = cracked, .content_type = "text/plain", .content_length = cracked.len });
        defer media.deinit();
        try expectError(&media, 415, "unsupported_media_type");
        var oversized = try f.server.dispatch(.{ .method = method, .target = path, .content_type = "application/json", .content_length = 65537 });
        defer oversized.deinit();
        try expectError(&oversized, 413, "request_body_too_large");
        const huge = [_]u8{'x'} ** 65537;
        var underreported = try f.server.dispatch(.{ .method = method, .target = path, .body = &huge, .content_type = "application/json", .content_length = 2 });
        defer underreported.deinit();
        try expectError(&underreported, 413, "request_body_too_large");
    }
    try f.sql("UPDATE web_sessions SET expires_at = now() - INTERVAL '1 second'");
    var expired = try f.get();
    defer expired.deinit();
    try expectError(&expired, 401, "authentication_required");
    try f.sql("UPDATE web_sessions SET expires_at = now() + INTERVAL '1 day', revoked_at = now()");
    var revoked = try f.get();
    defer revoked.deinit();
    try expectError(&revoked, 401, "authentication_required");
    var forged = try f.server.dispatch(.{ .method = .GET, .target = "/api/v1/account", .cookie = "mine_session=forged" });
    defer forged.deinit();
    try expectError(&forged, 401, "authentication_required");
    try f.audits("0");
}

test "account_routes_test audit insert failure rolls back application credentials and CSRF consumption" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.sql("ALTER TABLE audit_log ADD CONSTRAINT fail_task7 CHECK (action <> 'application_created')");
    const token = try f.csrf();
    var failed = try f.mutate(.POST, "/api/v1/account/application", cracked, &token);
    defer failed.deinit();
    try expectError(&failed, 500, "internal_error");
    try noSecrets(failed.body);
    try f.expectSql("SELECT count(*) FROM applications", "0");
    try f.expectSql("SELECT count(*) FROM password_credentials", "0");
    try f.audits("0");
    try f.sql("ALTER TABLE audit_log DROP CONSTRAINT fail_task7");
    var successful = try f.mutate(.POST, "/api/v1/account/application", cracked, &token);
    defer successful.deinit();
    try std.testing.expectEqual(@as(u16, 201), successful.status);
    try f.audits("1");
}

test "account_routes_test resubmit and password audit failures roll back content credentials metadata and CSRF" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.create(cracked);
    try f.sql("UPDATE applications SET status = 'rejected_retryable', decision_reason = 'Retry', decided_at = now(), decided_by_user_id = 1");
    try f.sql("ALTER TABLE audit_log ADD CONSTRAINT fail_task7 CHECK (action <> 'application_resubmitted')");
    const retry_token = try f.csrf();
    var failed_retry = try f.mutate(.PATCH, "/api/v1/account/application", retry_licensed, &retry_token);
    defer failed_retry.deinit();
    try expectError(&failed_retry, 500, "internal_error");
    try f.expectSql("SELECT minecraft_nickname || ':' || client_type || ':' || status || ':' || decision_reason FROM applications", "Example_Name:cracked:rejected_retryable:Retry");
    try f.expectSql("SELECT (decided_at IS NOT NULL AND decided_by_user_id = 1)::text FROM applications", "true");
    try f.expectSql("SELECT count(*) FROM password_credentials", "1");
    try f.audits("1");
    try f.sql("ALTER TABLE audit_log DROP CONSTRAINT fail_task7");
    var retry = try f.mutate(.PATCH, "/api/v1/account/application", cracked, &retry_token);
    defer retry.deinit();
    try std.testing.expectEqual(@as(u16, 200), retry.status);
    try f.audits("2");
    try f.sql("UPDATE applications SET status = 'approved'");
    try f.sql("ALTER TABLE audit_log ADD CONSTRAINT fail_task7 CHECK (action <> 'password_changed')");
    const password_token = try f.csrf();
    var failed_password = try f.mutate(.POST, "/api/v1/account/password", replacement, &password_token);
    defer failed_password.deinit();
    try expectError(&failed_password, 500, "internal_error");
    var credential = try f.database.pool.query("SELECT password_hash FROM password_credentials", &.{});
    defer credential.deinit();
    try std.testing.expect(try domain.password.verifyPassword(credential.value(0, 0), "blue-harbor-falcon-2026"));
    try f.audits("2");
    try f.sql("ALTER TABLE audit_log DROP CONSTRAINT fail_task7");
    var changed = try f.mutate(.POST, "/api/v1/account/password", replacement, &password_token);
    defer changed.deinit();
    try std.testing.expectEqual(@as(u16, 204), changed.status);
    try f.audits("3");
}

test "account_routes_test retry nickname rename rejects without changing application credential audit or CSRF" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.create(cracked);
    try f.sql("UPDATE applications SET status='rejected_retryable',decision_reason='Keep identity',decided_at=now(),decided_by_user_id=1");
    const token = try f.csrf();
    const snapshot = "SELECT json_build_object('application',(SELECT row_to_json(a) FROM applications a),'credential',(SELECT row_to_json(c) FROM password_credentials c),'audit',(SELECT json_agg(a ORDER BY id) FROM audit_log a),'sessions',(SELECT json_agg(s ORDER BY id) FROM web_sessions s))::text";
    var before = try f.database.pool.query(snapshot, &.{});
    defer before.deinit();
    for ([_][]const u8{ "Renamed_Player", "example_name" }) |name| {
        const body = try std.fmt.allocPrint(std.testing.allocator, "{{\"minecraft_nickname\":\"{s}\",\"client_type\":\"licensed\",\"about_me\":\"Changed content\",\"discovery_source\":\"Changed source\"}}", .{name});
        defer std.testing.allocator.free(body);
        var rejected = try f.mutate(.PATCH, "/api/v1/account/application", body, &token);
        defer rejected.deinit();
        try expectError(&rejected, 409, "nickname_immutable");
        try f.expectSql(snapshot, before.value(0, 0));
    }
    // the very same token remains usable; harmless trim is not a rename.
    var valid = try f.mutate(.PATCH, "/api/v1/account/application", retry_licensed, &token);
    defer valid.deinit();
    try std.testing.expectEqual(@as(u16, 200), valid.status);
    try f.expectSql("SELECT minecraft_nickname || ':' || minecraft_nickname_normalized || ':' || client_type || ':' || about_me FROM applications", "Example_Name:example_name:licensed:I build.");
    try f.audits("2");
}

test "account_routes_test retry rechecks nickname after waiting for the application lock" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.create(licensed);
    try f.sql("UPDATE applications SET status='rejected_retryable',decision_reason='Retry'");
    const token = try f.csrf();
    const Pool = @TypeOf(f.database.pool);
    var control = try Pool.open(std.testing.allocator, f.database.database_url);
    defer control.close();
    var transaction = try control.begin();
    var released = false;
    defer if (!released) transaction.rollback() catch {};
    var locked = try transaction.query("SELECT user_id FROM applications FOR UPDATE", &.{});
    locked.deinit();
    const Worker = struct {
        fixture: *Fixture,
        token: []const u8,
        status: u16 = 0,
        failure: ?anyerror = null,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        fn run(self: *@This()) void {
            defer self.done.store(true, .release);
            var result = self.fixture.mutate(.PATCH, "/api/v1/account/application", licensed, self.token) catch |err| {
                self.failure = err;
                return;
            };
            defer result.deinit();
            self.status = result.status;
        }
    };
    var worker = Worker{ .fixture = &f, .token = &token };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    defer thread.join();
    // always release the lock before joining, including assertion failures
    defer if (!released) {
        transaction.rollback() catch {};
        released = true;
    };
    var waiting = false;
    for (0..5000) |_| {
        var refreshed = try transaction.query("SELECT pg_stat_clear_snapshot()", &.{});
        refreshed.deinit();
        var activity = try transaction.query("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname=current_database() AND pid<>pg_backend_pid() AND wait_event_type='Lock' AND query LIKE 'SELECT status, client_type, minecraft_nickname%')::text", &.{});
        waiting = std.mem.eql(u8, activity.value(0, 0), "true");
        activity.deinit();
        if (waiting or worker.done.load(.acquire)) break;
        std.time.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(waiting);
    var renamed = try transaction.query("UPDATE applications SET minecraft_nickname='Admin_Renamed',minecraft_nickname_normalized='admin_renamed'", &.{});
    renamed.deinit();
    try transaction.commit();
    released = true;
    while (!worker.done.load(.acquire)) std.Thread.yield() catch {};
    if (worker.failure) |failure| return failure;
    try std.testing.expectEqual(@as(u16, 409), worker.status);
    try f.expectSql("SELECT minecraft_nickname || ':' || status || ':' || decision_reason FROM applications", "Admin_Renamed:rejected_retryable:Retry");
    try f.audits("1");
    // failure did not consume CSRF even after waiting on a concurrent edit.
    const updated = "{\"minecraft_nickname\":\"Admin_Renamed\",\"client_type\":\"licensed\",\"about_me\":\"I build.\",\"discovery_source\":\"Friend\"}";
    var retry = try f.mutate(.PATCH, "/api/v1/account/application", updated, &token);
    defer retry.deinit();
    try std.testing.expectEqual(@as(u16, 200), retry.status);
}

test "account_routes_test trimmed UTF-8 byte boundaries and nickname bounds are enforced" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const about = "é" ** 1000;
    const discovery = "é" ** 150;
    const body = try std.fmt.allocPrint(std.testing.allocator, "{{\"minecraft_nickname\":\" 0123456789ABCDEF \",\"client_type\":\"licensed\",\"about_me\":\" {s} \",\"discovery_source\":\" {s} \"}}", .{ about, discovery });
    defer std.testing.allocator.free(body);
    try f.create(body);
    try f.expectSql("SELECT octet_length(about_me)::text || ':' || octet_length(discovery_source)::text FROM applications", "2000:300");
    try f.sql("UPDATE applications SET status = 'rejected_retryable', decision_reason = 'Retry'");
    const invalid = "{\"minecraft_nickname\":\"0123456789ABCDEFG\",\"client_type\":\"licensed\",\"about_me\":\"Build\",\"discovery_source\":\"Friend\"}";
    const token = try f.csrf();
    var result = try f.mutate(.PATCH, "/api/v1/account/application", invalid, &token);
    defer result.deinit();
    try expectError(&result, 422, "invalid_minecraft_nickname");
    try f.audits("1");
}

test "account_routes_test session ownership ignores submitted actor role and status and rejects duplicate cookies" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.sql("INSERT INTO users (discord_id, discord_username) VALUES ('999999999999999999', 'Other user')");
    const spoofed = "{\"user_id\":2,\"role\":\"administrator\",\"status\":\"approved\",\"minecraft_nickname\":\"Example_Name\",\"client_type\":\"licensed\",\"about_me\":\"Build\",\"discovery_source\":\"Friend\"}";
    try f.create(spoofed);
    try f.expectSql("SELECT user_id::text || ':' || status FROM applications", "1:pending");
    const duplicated = try std.fmt.allocPrint(std.testing.allocator, "{s}; mine_session={s}", .{ f.cookie, f.issued.session_token });
    defer std.testing.allocator.free(duplicated);
    var duplicate = try f.server.dispatch(.{ .method = .GET, .target = "/api/v1/account", .cookie = duplicated });
    defer duplicate.deinit();
    try expectError(&duplicate, 401, "authentication_required");
    const token = try f.csrf();
    try f.sql("UPDATE web_sessions SET revoked_at = now()");
    for ([_]std.http.Method{ .POST, .PATCH, .POST }, [_][]const u8{ "/api/v1/account/application", "/api/v1/account/application", "/api/v1/account/password" }) |method, path| {
        var revoked = try f.mutate(method, path, cracked, &token);
        defer revoked.deinit();
        try expectError(&revoked, 401, "authentication_required");
    }
    try f.audits("1");
}
