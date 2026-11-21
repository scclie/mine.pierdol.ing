const std = @import("std");
const fake_mojang = @import("fake_mojang");
const mojang = @import("mojang");
const c = @cImport({
    @cInclude("stdlib.h");
});
const config = @import("config");
const auth = @import("auth");
const migrations = @import("migrations");
const postgres = @import("postgres");
const http = @import("http_server");
const discord = @import("discord");
const routes = @import("auth_routes");
const domain = @import("domain");
const db = @import("db_pool");

const Fixture = struct {
    database: postgres.TestDatabase,
    loaded: config.Config,
    provider: discord.DiscordService,
    router: routes.Router,
    server: http.Server,
    issued: auth.IssuedSession,
    cookie: []u8,
    context: u8 = 0,
    mojang: fake_mojang.Fake,
    resolver: mojang.Resolver,

    fn init(f: *Fixture) !void {
        f.database = try postgres.TestDatabase.create(std.testing.allocator, std.posix.getenv("TEST_DATABASE_URL") orelse return error.MissingTestDatabaseUrl);
        try migrations.apply(&f.database.pool);
        inline for (.{
            .{ "DATABASE_URL", "postgresql://unused" },
            .{ "HTTP_LISTEN_ADDRESS", "127.0.0.1:8088" },
            .{ "PUBLIC_ORIGIN", "http://127.0.0.1:3000" },
            .{ "DISCORD_CLIENT_ID", "test-client-id" },
            .{ "DISCORD_CLIENT_SECRET", "test-client-secret" },
            .{ "DISCORD_REDIRECT_URI", "http://127.0.0.1:3000/api/v1/auth/discord/callback" },
            .{ "SESSION_SIGNING_KEY", "0123456789abcdef0123456789abcdef" },
            .{ "GAME_AUTH_SERVER_CREDENTIALS", "sb:test-game-auth-secret" },
            .{ "ADMIN_DISCORD_IDS", "123456789012345678" },
            .{ "MODERATOR_DISCORD_IDS", "223456789012345678" },
            .{ "DEVELOPMENT_MODE", "true" },
        }) |pair| try std.testing.expectEqual(@as(c_int, 0), c.setenv(pair[0], pair[1], 1));
        f.loaded = try config.Config.load(std.testing.allocator);
        f.provider = discord.DiscordService.init(std.testing.allocator, &f.database.pool, &f.loaded, .{ .authorization_endpoint = "http://unused", .context = &f.context, .exchange = unusedExchange, .identity = unusedIdentity });
        f.mojang = .{ .uuid = try domain.mojang_uuid.Uuid.parseAdmin("4af7fe6c-cb9e-4012-bef8-adf078f34694") };
        f.resolver = f.mojang.resolver();
        f.router = try routes.Router.init(std.testing.allocator, &f.provider, &f.loaded, &f.resolver);
        f.server = http.Server.init(std.testing.allocator);
        try routes.register(&f.server, &f.router);
        try f.sql("INSERT INTO users (discord_id, discord_username, discord_global_name, discord_avatar_hash) VALUES ('123456789012345678','Admin',NULL,NULL), ('423456789012345678','Subject','Old Name','old-avatar'), ('523456789012345678','Other',NULL,NULL)");
        try f.sql("INSERT INTO applications (user_id,minecraft_nickname,minecraft_nickname_normalized,client_type,about_me,discovery_source,submitted_at) VALUES (2,'Subject_Name','subject_name','licensed','Build','Friend','2026-01-01'), (3,'Other_Name','other_name','licensed','Build','Friend','2026-01-02')");
        var service = auth.AuthService.init(std.testing.allocator, &f.database.pool, &f.loaded);
        f.issued = try service.createSession(1);
        f.cookie = try std.fmt.allocPrint(std.testing.allocator, "mine_session={s}", .{f.issued.session_token});
        var subject = try service.createSession(2);
        subject.deinit(std.testing.allocator);
        subject = try service.createSession(2);
        subject.deinit(std.testing.allocator);
    }
    fn deinit(f: *Fixture) void {
        std.testing.allocator.free(f.cookie);
        f.issued.deinit(std.testing.allocator);
        f.server.deinit();
        f.router.deinit();
        f.loaded.deinit();
        f.database.deinit();
    }
    fn sql(f: *Fixture, query: []const u8) !void {
        var r = try f.database.pool.query(query, &.{});
        r.deinit();
    }
    fn state(f: *Fixture) ![]u8 {
        var r = try f.database.pool.query("SELECT md5(jsonb_build_array((SELECT jsonb_agg(to_jsonb(u) ORDER BY id) FROM users u),(SELECT jsonb_agg(to_jsonb(a) ORDER BY user_id) FROM applications a),(SELECT jsonb_agg(to_jsonb(g) ORDER BY user_id) FROM game_identities g),(SELECT jsonb_agg(to_jsonb(p) ORDER BY user_id) FROM password_credentials p),(SELECT jsonb_agg(to_jsonb(s) ORDER BY id) FROM web_sessions s),(SELECT jsonb_agg(to_jsonb(l) ORDER BY id) FROM audit_log l),(SELECT jsonb_agg(to_jsonb(c)) FROM game_auth_whitelist_state c))::text)", &.{});
        defer r.deinit();
        return std.testing.allocator.dupe(u8, r.value(0, 0));
    }
    fn expectSql(f: *Fixture, query: []const u8, expected: []const u8) !void {
        var r = try f.database.pool.query(query, &.{});
        defer r.deinit();
        try std.testing.expectEqualStrings(expected, r.value(0, 0));
    }
    fn get(f: *Fixture, target: []const u8) !http.response.Response {
        return f.server.dispatch(.{ .method = .GET, .target = target, .cookie = f.cookie });
    }
    fn csrf(f: *Fixture) ![64]u8 {
        var r = try f.get("/api/v1/account");
        defer r.deinit();
        try std.testing.expectEqual(@as(u16, 200), r.status);
        const p = try parse(r.body);
        defer p.deinit();
        var token: [64]u8 = undefined;
        @memcpy(&token, p.value.object.get("csrf_token").?.string);
        return token;
    }
    fn mutate(f: *Fixture, method: std.http.Method, path: []const u8, body: []const u8, token: ?[]const u8) !http.response.Response {
        return f.server.dispatch(.{ .method = method, .target = path, .cookie = f.cookie, .body = body, .csrf_token = token, .content_type = "application/json", .content_length = body.len });
    }
    fn change(f: *Fixture, method: std.http.Method, path: []const u8, body: []const u8, status: u16, code: ?[]const u8) !void {
        const token = try f.csrf();
        var r = try f.mutate(method, path, body, &token);
        defer r.deinit();
        if (code) |value| try expectError(&r, status, value) else try std.testing.expectEqual(status, r.status);
        try noSecrets(r.body);
    }
};
fn unusedExchange(_: *anyopaque, _: []const u8, _: []const u8) ![]const u8 {
    return error.UnexpectedProviderCall;
}
fn unusedIdentity(_: *anyopaque, _: []const u8) !discord.DiscordIdentity {
    return error.UnexpectedProviderCall;
}
fn parse(body: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
}
fn noSecrets(body: []const u8) !void {
    for ([_][]const u8{ "password_hash", "argon2", "stale-secret", "csrf_token_hash", "token_hash", "test-client-secret", "pkce_verifier" }) |secret| try std.testing.expect(std.mem.indexOf(u8, body, secret) == null);
}
fn expectError(r: *const http.response.Response, status: u16, code: []const u8) !void {
    try std.testing.expectEqual(status, r.status);
    const p = try parse(r.body);
    defer p.deinit();
    try std.testing.expectEqualStrings(code, p.value.object.get("error").?.object.get("code").?.string);
    try std.testing.expect(r.header("X-Request-ID") != null);
    try noSecrets(r.body);
}

test "admin_routes_test incident repair binds without toggles and card exposes UUID revision" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.sql("UPDATE applications SET minecraft_nickname='paper_sacculos',minecraft_nickname_normalized='paper_sacculos',status='approved' WHERE user_id=2");
    try f.sql("CREATE TEMP TABLE repair_before AS SELECT identity_id,authentication_generation FROM game_identities WHERE user_id=2");
    try f.sql("CREATE TEMP TABLE repair_cursor AS SELECT version FROM game_auth_whitelist_state");
    var card = try f.get("/api/v1/admin/users/2");
    defer card.deinit();
    const p = try parse(card.body);
    defer p.deinit();
    try std.testing.expect(p.value.object.get("application").?.object.get("licensed_mojang_uuid") != null);
    try std.testing.expect(p.value.object.get("application").?.object.get("licensed_mojang_uuid").? == .null);
    try std.testing.expect(p.value.object.get("application").?.object.get("identity_revision") != null);
    try std.testing.expect(p.value.object.get("application").?.object.get("identity_revision").? == .string);
    try f.change(.PATCH, "/api/v1/admin/users/2", "{\"resolve_licensed_mojang_uuid\":true}", 204, null);
    try f.expectSql("SELECT licensed_mojang_uuid::text FROM game_identities WHERE user_id=2", "4af7fe6c-cb9e-4012-bef8-adf078f34694");
    try f.expectSql("SELECT status::text FROM applications WHERE user_id=2", "approved");
    try f.expectSql("SELECT count(*) FROM audit_log WHERE action='user_client_type_changed'", "0");
    try f.expectSql("SELECT count(*) FROM password_credentials", "0");
    try f.expectSql("SELECT g.identity_id=b.identity_id AND g.authentication_generation>b.authentication_generation FROM game_identities g,repair_before b WHERE g.user_id=2", "t");
    try f.expectSql("SELECT c.version>b.version FROM game_auth_whitelist_state c,repair_cursor b", "t");
    try f.expectSql("SELECT count(*) FROM audit_log WHERE action='licensed_mojang_uuid_changed' AND old_value->>'licensed_mojang_uuid' IS NULL AND new_value->>'licensed_mojang_uuid'='4af7fe6c-cb9e-4012-bef8-adf078f34694'", "1");
    try f.change(.PATCH, "/api/v1/admin/users/2", "{\"resolve_licensed_mojang_uuid\":true}", 409, "licensed_mojang_uuid_already_resolved");
}

test "admin_routes_test manual UUID requires confirmation reason administrator and audits uniqueness" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const uuid = "4af7fe6c-cb9e-4012-bef8-adf078f34694";
    try f.change(.PATCH, "/api/v1/admin/users/2", "{\"licensed_mojang_uuid\":\"" ++ uuid ++ "\",\"reason\":\"Incident\"}", 422, "uuid_override_confirmation_required");
    try f.change(.PATCH, "/api/v1/admin/users/2", "{\"licensed_mojang_uuid\":\"" ++ uuid ++ "\",\"confirm_uuid_override\":true}", 422, "reason_required");
    const body = "{\"licensed_mojang_uuid\":\"" ++ uuid ++ "\",\"confirm_uuid_override\":true,\"reason\":\"Incident\"}";
    try f.sql("UPDATE users SET discord_id='223456789012345678' WHERE id=1");
    try f.change(.PATCH, "/api/v1/admin/users/2", body, 403, "insufficient_role");
    try f.sql("UPDATE users SET discord_id='123456789012345678' WHERE id=1");
    f.mojang.failure = error.MinecraftProfileLookupUnavailable;
    try f.change(.PATCH, "/api/v1/admin/users/2", body, 204, null);
    try f.sql("CREATE TEMP TABLE manual_before AS SELECT application_revision,version FROM users,game_auth_whitelist_state WHERE id=2");
    try f.change(.PATCH, "/api/v1/admin/users/2", body, 204, null);
    try f.expectSql("SELECT u.application_revision=b.application_revision+1 AND c.version=b.version FROM users u,game_auth_whitelist_state c,manual_before b WHERE u.id=2", "t");
    try f.expectSql("SELECT count(*) FROM audit_log WHERE action='licensed_mojang_uuid_changed' AND reason='Incident' AND new_value->>'source'='manual_admin'", "2");
    try f.change(.PATCH, "/api/v1/admin/users/3", body, 409, "licensed_mojang_uuid_in_use");
    try std.testing.expectEqual(@as(usize, 0), f.mojang.calls);
}

test "admin_routes_test licensed decisions resolve bound approval unban and cracked clear" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.change(.POST, "/api/v1/admin/applications/2/approve", "{}", 204, null);
    try f.expectSql("SELECT licensed_mojang_uuid IS NOT NULL FROM game_identities WHERE user_id=2", "t");
    try f.change(.PATCH, "/api/v1/admin/users/2", "{\"status\":\"banned\",\"reason\":\"No\"}", 204, null);
    f.mojang.uuid = try domain.mojang_uuid.Uuid.parseAdmin("7af7fe6c-cb9e-4012-bef8-adf078f34694");
    try f.change(.PATCH, "/api/v1/admin/users/2", "{\"status\":\"approved\"}", 409, "licensed_mojang_uuid_mismatch");
    f.mojang.uuid = try domain.mojang_uuid.Uuid.parseAdmin("4af7fe6c-cb9e-4012-bef8-adf078f34694");
    try f.change(.PATCH, "/api/v1/admin/users/2", "{\"status\":\"approved\"}", 204, null);
    f.mojang.failure = error.MinecraftProfileLookupUnavailable;
    try f.change(.PATCH, "/api/v1/admin/users/2", "{\"client_type\":\"cracked\"}", 204, null);
    try f.expectSql("SELECT licensed_mojang_uuid IS NULL FROM game_identities WHERE user_id=2", "t");
    try std.testing.expectEqual(@as(usize, 3), f.mojang.calls);
}

test "admin_routes_test failed lookup preserves full state and original CSRF" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const token = try f.csrf();
    const before = try f.state();
    defer std.testing.allocator.free(before);
    for ([_]anyerror{ error.MinecraftProfileNotFound, error.MinecraftProfileLookupUnavailable, error.MinecraftProfileLookupInvalid }, [_]u16{ 422, 503, 502 }, [_][]const u8{ "minecraft_profile_not_found", "minecraft_profile_lookup_unavailable", "minecraft_profile_lookup_invalid" }) |failure, status, code| {
        f.mojang.failure = failure;
        var r = try f.mutate(.POST, "/api/v1/admin/applications/2/approve", "{}", &token);
        defer r.deinit();
        try expectError(&r, status, code);
        try std.testing.expectEqualStrings("no-store", r.header("Cache-Control").?);
        const after = try f.state();
        defer std.testing.allocator.free(after);
        try std.testing.expectEqualStrings(before, after);
    }
    f.mojang.failure = null;
    var retry = try f.mutate(.POST, "/api/v1/admin/applications/2/approve", "{}", &token);
    defer retry.deinit();
    try std.testing.expectEqual(@as(u16, 204), retry.status);
}

test "admin_routes_test UUID validation repair boundaries and combined final state" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const cases = [_]struct { body: []const u8, code: []const u8, status: u16 = 422 }{
        .{ .body = "{\"licensed_mojang_uuid\":\"\"}", .code = "invalid_licensed_mojang_uuid" },
        .{ .body = "{\"licensed_mojang_uuid\":\"00000000-0000-0000-0000-000000000000\"}", .code = "invalid_licensed_mojang_uuid" },
        .{ .body = "{\"licensed_mojang_uuid\":null}", .code = "licensed_mojang_uuid_required" },
        .{ .body = "{\"resolve_licensed_mojang_uuid\":true,\"status\":\"approved\"}", .code = "invalid_uuid_operation" },
        .{ .body = "{\"resolve_licensed_mojang_uuid\":true,\"resolve_licensed_mojang_uuid\":true}", .code = "invalid_json", .status = 400 },
        .{ .body = "{\"resolve_licensed_mojang_uuid\":true,\"identity_revision\":\"+1\"}", .code = "invalid_identity_revision" },
        .{ .body = "{\"resolve_licensed_mojang_uuid\":true,\"identity_revision\":\"9223372036854775808\"}", .code = "invalid_identity_revision" },
        .{ .body = "{\"resolve_licensed_mojang_uuid\":true,\"identity_revision\":\"0\"}", .code = "identity_changed", .status = 409 },
    };
    for (cases) |case| try f.change(.PATCH, "/api/v1/admin/users/2", case.body, case.status, case.code);
    try std.testing.expectEqual(@as(usize, 0), f.mojang.calls);
    try f.sql("UPDATE applications SET client_type='cracked' WHERE user_id=2");
    try f.change(.PATCH, "/api/v1/admin/users/2", "{\"resolve_licensed_mojang_uuid\":true}", 422, "licensed_mojang_uuid_not_applicable");
    try f.sql("INSERT INTO password_credentials(user_id,password_hash) VALUES (2,'stale-secret')");
    try f.change(.PATCH, "/api/v1/admin/users/2", "{\"client_type\":\"licensed\",\"minecraft_nickname\":\"Final_Name\",\"status\":\"approved\"}", 204, null);
    try f.expectSql("SELECT minecraft_nickname || ':' || client_type || ':' || status FROM applications WHERE user_id=2", "Final_Name:licensed:approved");
    try f.expectSql("SELECT count(*) FROM password_credentials WHERE user_id=2", "0");
    try std.testing.expectEqualStrings("Final_Name", f.mojang.last_name.?.display());
    try f.sql("DELETE FROM game_identities WHERE user_id=2");
    try f.change(.PATCH, "/api/v1/admin/users/2", "{\"resolve_licensed_mojang_uuid\":true}", 500, "internal_error");
    try f.change(.PATCH, "/api/v1/admin/users/1", "{\"resolve_licensed_mojang_uuid\":true}", 404, "application_not_found");
    try f.change(.PATCH, "/api/v1/admin/users/1", "{\"discord_id\":\"123456789012345678\"}", 204, null);
    var card = try f.get("/api/v1/admin/users/1");
    defer card.deinit();
    const p = try parse(card.body);
    defer p.deinit();
    try std.testing.expect(p.value.object.get("application").? == .null);
}

test "admin_routes_test licensed preparation stale preserves competing commit" {
    for ([_][]const u8{
        "UPDATE applications SET minecraft_nickname='Competing',minecraft_nickname_normalized='competing' WHERE user_id=2",
        "UPDATE applications SET status='approved' WHERE user_id=2",
        "UPDATE applications SET client_type='cracked' WHERE user_id=2",
        "UPDATE applications SET status='approved' WHERE user_id=2; UPDATE applications SET status='pending' WHERE user_id=2",
        "UPDATE applications SET client_type='cracked' WHERE user_id=2; UPDATE applications SET client_type='licensed' WHERE user_id=2",
        "UPDATE game_identities SET licensed_mojang_uuid='7af7fe6c-cb9e-4012-bef8-adf078f34694' WHERE user_id=2",
        "DELETE FROM game_identities WHERE user_id=2",
    }) |sql| {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        const Hook = struct {
            fixture: *Fixture,
            sql: []const u8,
            after: ?[]u8 = null,
            fn run(ctx: *anyopaque) !void {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                var other = try db.Pool.open(std.testing.allocator, self.fixture.database.database_url);
                defer other.close();
                var commands = std.mem.splitScalar(u8, self.sql, ';');
                while (commands.next()) |command| try execute(&other, command);
                self.after = try self.fixture.state();
            }
        };
        var hook = Hook{ .fixture = &f, .sql = sql };
        defer if (hook.after) |value| std.testing.allocator.free(value);
        f.mojang.before_return = Hook.run;
        f.mojang.hook_context = &hook;
        const token = try f.csrf();
        var r = try f.mutate(.POST, "/api/v1/admin/applications/2/approve", "{}", &token);
        defer r.deinit();
        try expectError(&r, 409, "identity_changed");
        const after = try f.state();
        defer std.testing.allocator.free(after);
        try std.testing.expectEqualStrings(hook.after.?, after);
    }
}

test "admin_routes_test repository rejects missing future expired preparation at locked boundary" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const token = try f.csrf();
    const repo = &f.router.admin_router.application_service.repository;
    const snapshot = try repo.readAdmissionSnapshot(2);
    var prepared = domain.licensed_admission.Prepared{
        .expected = snapshot,
        .intent = .{ .operation = .approve, .status = .approved },
        .observation = null,
    };
    const proof = .{ .token_hash = proofHash(&f.issued.session_token), .csrf_hash = proofHash(&token), .next_csrf_hash = proofHash("next") };
    const before = try f.state();
    defer std.testing.allocator.free(before);
    try std.testing.expectError(error.MojangObservationRequired, repo.mutateAdmin(&f.router.admin_router.auth_service, 1, 2, .approve, .{ .status = .approved }, proof, prepared, &f.resolver.clock));
    prepared.observation = .{ .requested = snapshot.application.?.nickname, .returned = snapshot.application.?.nickname, .uuid = f.mojang.uuid.?, .observed_ns = 1 };
    try std.testing.expectError(error.IdentityChanged, repo.mutateAdmin(&f.router.admin_router.auth_service, 1, 2, .approve, .{ .status = .approved }, proof, prepared, &f.resolver.clock));
    prepared.observation.?.observed_ns = 0;
    f.mojang.now_ns = 10 * std.time.ns_per_s + 1;
    try std.testing.expectError(error.IdentityChanged, repo.mutateAdmin(&f.router.admin_router.auth_service, 1, 2, .approve, .{ .status = .approved }, proof, prepared, &f.resolver.clock));
    const after = try f.state();
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
    f.mojang.now_ns = 10 * std.time.ns_per_s;
    try repo.mutateAdmin(&f.router.admin_router.auth_service, 1, 2, .approve, .{ .status = .approved }, proof, prepared, &f.resolver.clock);
    try f.expectSql("SELECT status::text FROM applications WHERE user_id=2", "approved");
}

fn proofHash(token: []const u8) [66]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    var out: [66]u8 = undefined;
    out[0..2].* = "\\x".*;
    out[2..].* = std.fmt.bytesToHex(digest, .lower);
    return out;
}

test "admin_routes_test converted cracked subject sees password setup requirement on own account" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.sql("UPDATE applications SET status='approved' WHERE user_id=2");
    try f.change(.PATCH, "/api/v1/admin/users/2", "{\"client_type\":\"cracked\"}", 204, null);
    var service = auth.AuthService.init(std.testing.allocator, &f.database.pool, &f.loaded);
    var session = try service.createSession(2);
    defer session.deinit(std.testing.allocator);
    const cookie = try std.fmt.allocPrint(std.testing.allocator, "mine_session={s}", .{session.session_token});
    defer std.testing.allocator.free(cookie);
    var own = try f.server.dispatch(.{ .method = .GET, .target = "/api/v1/account", .cookie = cookie });
    defer own.deinit();
    try std.testing.expectEqual(@as(u16, 200), own.status);
    const p = try parse(own.body);
    defer p.deinit();
    try std.testing.expect(p.value.object.contains("password_setup_required"));
    try std.testing.expect(p.value.object.get("password_setup_required").?.bool);
    try noSecrets(own.body);
}

test "admin_routes_test converted cracked subject can set first password with audit and CSRF rollback" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.sql("UPDATE applications SET status='approved' WHERE user_id=2");
    try f.change(.PATCH, "/api/v1/admin/users/2", "{\"client_type\":\"cracked\"}", 204, null);
    var service = auth.AuthService.init(std.testing.allocator, &f.database.pool, &f.loaded);
    var session = try service.createSession(2);
    defer session.deinit(std.testing.allocator);
    const cookie = try std.fmt.allocPrint(std.testing.allocator, "mine_session={s}", .{session.session_token});
    defer std.testing.allocator.free(cookie);
    const body = "{\"password\":\"blue-harbor-falcon-2026\"}";
    try f.sql("ALTER TABLE audit_log ADD CONSTRAINT fail_setup CHECK (action <> 'password_changed')");
    var failed = try f.server.dispatch(.{ .method = .POST, .target = "/api/v1/account/password", .cookie = cookie, .csrf_token = &session.csrf_token, .body = body, .content_type = "application/json", .content_length = body.len });
    defer failed.deinit();
    try expectError(&failed, 500, "internal_error");
    try f.expectSql("SELECT count(*) FROM password_credentials WHERE user_id=2", "0");
    try f.sql("ALTER TABLE audit_log DROP CONSTRAINT fail_setup");
    var success = try f.server.dispatch(.{ .method = .POST, .target = "/api/v1/account/password", .cookie = cookie, .csrf_token = &session.csrf_token, .body = body, .content_type = "application/json", .content_length = body.len });
    defer success.deinit();
    try std.testing.expectEqual(@as(u16, 204), success.status);
    var credential = try f.database.pool.query("SELECT password_hash FROM password_credentials WHERE user_id=2", &.{});
    defer credential.deinit();
    try std.testing.expect(try domain.password.verifyPassword(credential.value(0, 0), "blue-harbor-falcon-2026"));
    var card = try f.get("/api/v1/admin/users/2");
    defer card.deinit();
    const p = try parse(card.body);
    defer p.deinit();
    try std.testing.expect(!p.value.object.get("password_setup_required").?.bool);
    try f.expectSql("SELECT count(*) FROM audit_log WHERE actor_user_id=2 AND subject_user_id=2 AND action='password_changed' AND old_value IS NULL AND new_value IS NULL", "1");
}

test "admin_routes_test roles are dynamically resolved and all endpoints require active authentication" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    for ([_][]const u8{ "323456789012345678", "223456789012345678", "123456789012345678" }, [_]u16{ 403, 200, 200 }) |id, status| {
        var changed = try f.database.pool.query("UPDATE users SET discord_id=$1 WHERE id=1", &.{id});
        changed.deinit();
        var queue = try f.get("/api/v1/admin/applications");
        defer queue.deinit();
        if (status == 403) try expectError(&queue, status, "insufficient_role") else try std.testing.expectEqual(status, queue.status);
        var card = try f.get("/api/v1/admin/users/2");
        defer card.deinit();
        try std.testing.expectEqual(status, card.status);
        if (status != 403 and std.mem.eql(u8, id, "223456789012345678")) try f.change(.PATCH, "/api/v1/admin/users/2", "{\"minecraft_nickname\":\"NewName\"}", 403, "insufficient_role");
    }
    try f.sql("UPDATE web_sessions SET revoked_at=now() WHERE user_id=1");
    for ([_][]const u8{ "/api/v1/admin/applications", "/api/v1/admin/users/2" }) |path| {
        var r = try f.get(path);
        defer r.deinit();
        try expectError(&r, 401, "authentication_required");
    }
    for ([_]std.http.Method{ .POST, .POST, .PATCH }, [_][]const u8{ "/api/v1/admin/applications/2/approve", "/api/v1/admin/applications/2/reject", "/api/v1/admin/users/2" }) |method, path| {
        var r = try f.mutate(method, path, "{}", &f.issued.csrf_token);
        defer r.deinit();
        try expectError(&r, 401, "authentication_required");
    }
}

test "admin_routes_test queue defaults oldest first stable pagination exact searches and safe cards" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.sql("UPDATE applications SET submitted_at='2026-01-01' WHERE user_id=3");
    var first = try f.get("/api/v1/admin/applications?status=pending&limit=1");
    defer first.deinit();
    try std.testing.expectEqual(@as(u16, 200), first.status);
    const p = try parse(first.body);
    defer p.deinit();
    const items = p.value.object.get("applications").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqual(@as(i64, 2), items[0].object.get("user_id").?.integer);
    const cursor = p.value.object.get("next_cursor").?.string;
    try std.testing.expect(std.mem.indexOf(u8, cursor, "SELECT") == null);
    const target = try std.fmt.allocPrint(std.testing.allocator, "/api/v1/admin/applications?limit=1&cursor={s}", .{cursor});
    defer std.testing.allocator.free(target);
    var next = try f.get(target);
    defer next.deinit();
    try std.testing.expectEqual(@as(u16, 200), next.status);
    const n = try parse(next.body);
    defer n.deinit();
    try std.testing.expectEqual(@as(i64, 3), n.value.object.get("applications").?.array.items[0].object.get("user_id").?.integer);
    try std.testing.expect(n.value.object.get("next_cursor").? == .null);
    for ([_][]const u8{ "Subject_Name", "423456789012345678", "2", "%25", "423456", "Build" }, [_]usize{ 1, 1, 1, 0, 0, 0 }) |query, count| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "/api/v1/admin/applications?query={s}", .{query});
        defer std.testing.allocator.free(path);
        var r = try f.get(path);
        defer r.deinit();
        try std.testing.expectEqual(@as(u16, 200), r.status);
        const q = try parse(r.body);
        defer q.deinit();
        try std.testing.expectEqual(count, q.value.object.get("applications").?.array.items.len);
        try noSecrets(r.body);
    }
    var card = try f.get("/api/v1/admin/users/2");
    defer card.deinit();
    try std.testing.expectEqual(@as(u16, 200), card.status);
    try noSecrets(card.body);
    const card_json = try parse(card.body);
    defer card_json.deinit();
    try std.testing.expect(!card_json.value.object.get("password_setup_required").?.bool);
    for ([_][]const u8{ "status=unknown", "limit=0", "limit=101", "limit=-1", "limit=1x", "limit=", "cursor=bad", "status=pending&status=approved", "query=%00", "query=%ZZ", "unknown=x" }) |query| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "/api/v1/admin/applications?{s}", .{query});
        defer std.testing.allocator.free(path);
        var r = try f.get(path);
        defer r.deinit();
        try expectError(&r, 422, "invalid_query");
    }
    var missing = try f.get("/api/v1/admin/users/999");
    defer missing.deinit();
    try expectError(&missing, 404, "user_not_found");
    for ([_][]const u8{ "0", "-1", "9223372036854775808", "abc", "2x" }) |id| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "/api/v1/admin/users/{s}", .{id});
        defer std.testing.allocator.free(path);
        var r = try f.get(path);
        defer r.deinit();
        try expectError(&r, 422, "invalid_id");
    }
}

test "admin_routes_test pending decisions consume CSRF set decision metadata and audit atomically" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.sql("UPDATE users SET discord_id='223456789012345678' WHERE id=1");
    const token = try f.csrf();
    var approved = try f.mutate(.POST, "/api/v1/admin/applications/2/approve", "{}", &token);
    defer approved.deinit();
    try std.testing.expectEqual(@as(u16, 204), approved.status);
    try f.expectSql("SELECT status || ':' || (decided_at IS NOT NULL AND decided_by_user_id=1 AND decision_reason IS NULL)::text FROM applications WHERE user_id=2", "approved:true");
    var replay = try f.mutate(.POST, "/api/v1/admin/applications/3/approve", "{}", &token);
    defer replay.deinit();
    try expectError(&replay, 403, "csrf_token_invalid");
    try f.change(.POST, "/api/v1/admin/applications/2/approve", "{}", 409, "application_not_pending");
    try f.change(.POST, "/api/v1/admin/applications/2/reject", "{\"kind\":\"final\",\"reason\":\"No\"}", 409, "application_not_pending");
    try f.change(.POST, "/api/v1/admin/applications/3/reject", "{\"kind\":\"retryable\",\"reason\":\"  \"}", 422, "reason_required");
    try f.change(.POST, "/api/v1/admin/applications/3/reject", "{\"kind\":\"final\",\"reason\":\"  No thanks  \"}", 204, null);
    try f.expectSql("SELECT status || ':' || decision_reason || ':' || (decided_at IS NOT NULL AND decided_by_user_id=1)::text FROM applications WHERE user_id=3", "rejected_final:No thanks:true");
    try f.expectSql("SELECT count(*) FROM audit_log WHERE actor_user_id=1 AND old_value->>'status'='pending' AND ((action='application_approved' AND new_value->>'status'='approved') OR (action='application_rejected_final' AND new_value->>'status'='rejected_final' AND reason='No thanks'))", "2");
    try f.sql("UPDATE applications SET status='pending', decision_reason=NULL WHERE user_id=3");
    try f.change(.POST, "/api/v1/admin/applications/3/reject", "{\"kind\":\"retryable\",\"reason\":\"Try again\"}", 204, null);
    try f.expectSql("SELECT count(*) FROM audit_log WHERE action='application_rejected_retryable'", "1");
    for ([_][]const u8{ "approved", "rejected_retryable", "rejected_final", "banned" }) |status| {
        var changed = try f.database.pool.query("UPDATE applications SET status=$1::application_status, decision_reason=CASE WHEN $1='approved' THEN NULL ELSE 'Reason' END WHERE user_id=3", &.{status});
        changed.deinit();
        try f.change(.POST, "/api/v1/admin/applications/3/approve", "{}", 409, "application_not_pending");
    }
}

test "admin_routes_test strict patch validation uniqueness identity metadata and safe audit" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const cases = [_]struct { body: []const u8, code: []const u8, status: u16 = 422 }{
        .{ .body = "{}", .code = "empty_patch" },                                                           .{ .body = "[]", .code = "invalid_json", .status = 400 },                                              .{ .body = "{", .code = "invalid_json", .status = 400 },
        .{ .body = "{\"role\":\"administrator\"}", .code = "invalid_patch_field" },                         .{ .body = "{\"password\":\"stale-secret\"}", .code = "invalid_patch_field" },                         .{ .body = "{\"minecraft_nickname\":null}", .code = "invalid_minecraft_nickname" },
        .{ .body = "{\"minecraft_nickname\":\"bad-name\"}", .code = "invalid_minecraft_nickname" },         .{ .body = "{\"discord_id\":42}", .code = "invalid_discord_id" },                                      .{ .body = "{\"discord_id\":\"0\"}", .code = "invalid_discord_id" },
        .{ .body = "{\"discord_id\":\"18446744073709551616\"}", .code = "invalid_discord_id" },             .{ .body = "{\"client_type\":\"other\"}", .code = "invalid_client_type" },                             .{ .body = "{\"status\":\"other\"}", .code = "invalid_status" },
        .{ .body = "{\"reason\":\"only\"}", .code = "empty_patch" },                                        .{ .body = "{\"status\":\"banned\"}", .code = "reason_required" },                                     .{ .body = "{\"status\":\"banned\",\"reason\":false}", .code = "invalid_reason" },
        .{ .body = "{\"discord_id\":\"523456789012345678\"}", .code = "discord_id_in_use", .status = 409 }, .{ .body = "{\"minecraft_nickname\":\"OTHER_NAME\"}", .code = "nickname_unavailable", .status = 409 }, .{ .body = "{\"status\":\"pending\"}", .code = "invalid_status_transition", .status = 409 },
    };
    for (cases) |case| try f.change(.PATCH, "/api/v1/admin/users/2", case.body, case.status, case.code);
    try f.expectSql("SELECT count(*) FROM audit_log", "0");
    try f.change(.PATCH, "/api/v1/admin/users/2", "{\"minecraft_nickname\":\" NewName \"}", 204, null);
    try f.expectSql("SELECT minecraft_nickname || ':' || minecraft_nickname_normalized FROM applications WHERE user_id=2", "NewName:newname");
    try f.expectSql("SELECT count(*) FROM audit_log WHERE action='user_nickname_changed' AND old_value->>'nickname'='Subject_Name' AND new_value->>'nickname'='NewName' AND actor_user_id=1 AND subject_user_id=2", "1");
    try f.change(.PATCH, "/api/v1/admin/users/2", "{\"discord_id\":\"623456789012345678\"}", 204, null);
    try f.expectSql("SELECT discord_id || ':' || discord_username || ':' || (discord_global_name IS NULL AND discord_avatar_hash IS NULL)::text FROM users WHERE id=2", "623456789012345678::true");
    try f.expectSql("SELECT count(*) FROM web_sessions WHERE user_id=2 AND revoked_at IS NULL", "0");
    try f.expectSql("SELECT count(*) FROM audit_log WHERE action='user_discord_id_changed' AND old_value->>'discord_id'='423456789012345678' AND new_value->>'discord_id'='623456789012345678'", "1");
    var audit = try f.database.pool.query("SELECT json_agg(audit_log)::text FROM audit_log", &.{});
    defer audit.deinit();
    try noSecrets(audit.value(0, 0));
}

test "admin_routes_test ban unban and client changes delete stale credentials revoke sessions and expose password setup" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.sql("UPDATE applications SET status='approved' WHERE user_id=2");
    try f.sql("INSERT INTO password_credentials (user_id,password_hash) VALUES (2,'stale-secret')");
    try f.change(.PATCH, "/api/v1/admin/users/2", "{\"client_type\":\"cracked\"}", 204, null);
    try f.expectSql("SELECT count(*) FROM password_credentials WHERE user_id=2", "0");
    var card = try f.get("/api/v1/admin/users/2");
    defer card.deinit();
    const p = try parse(card.body);
    defer p.deinit();
    try std.testing.expect(p.value.object.get("password_setup_required").?.bool);
    try f.sql("INSERT INTO password_credentials (user_id,password_hash) VALUES (2,'stale-secret')");
    try f.change(.PATCH, "/api/v1/admin/users/2", "{\"client_type\":\"licensed\"}", 204, null);
    try f.expectSql("SELECT count(*) FROM password_credentials WHERE user_id=2", "0");
    try f.change(.PATCH, "/api/v1/admin/users/2", "{\"status\":\"banned\",\"reason\":\" Repeated rule violations \"}", 204, null);
    try f.expectSql("SELECT status || ':' || decision_reason FROM applications WHERE user_id=2", "banned:Repeated rule violations");
    try f.expectSql("SELECT count(*) FROM web_sessions WHERE user_id=2 AND revoked_at IS NULL", "0");
    try f.change(.PATCH, "/api/v1/admin/users/2", "{\"status\":\"approved\"}", 204, null);
    try f.expectSql("SELECT count(*) FROM audit_log WHERE action='user_unbanned' AND old_value->>'status'='banned' AND new_value->>'status'='approved'", "1");
    try f.expectSql("SELECT count(*) FROM audit_log WHERE action='user_banned' AND reason='Repeated rule violations'", "1");
    try f.expectSql("SELECT (decision_reason IS NULL)::text FROM applications WHERE user_id=2", "true");
}

test "admin_routes_test mutations require CSRF reject malformed decisions and enforce JSON bounds" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    for ([_]std.http.Method{ .POST, .POST, .PATCH }, [_][]const u8{ "/api/v1/admin/applications/2/approve", "/api/v1/admin/applications/2/reject", "/api/v1/admin/users/2" }) |method, path| {
        var missing = try f.mutate(method, path, "{}", null);
        defer missing.deinit();
        try expectError(&missing, 403, "csrf_token_required");
        var wrong = try f.mutate(method, path, "{}", "bad");
        defer wrong.deinit();
        try expectError(&wrong, 403, "csrf_token_invalid");
        var media = try f.server.dispatch(.{ .method = method, .target = path, .content_type = "text/plain", .content_length = 2 });
        defer media.deinit();
        try expectError(&media, 415, "unsupported_media_type");
        var huge = try f.server.dispatch(.{ .method = method, .target = path, .content_type = "application/json", .content_length = 65537 });
        defer huge.deinit();
        try expectError(&huge, 413, "request_body_too_large");
    }
    try f.change(.POST, "/api/v1/admin/applications/2/reject", "{\"kind\":\"other\",\"reason\":\"No\"}", 422, "invalid_rejection_kind");
    try f.change(.POST, "/api/v1/admin/applications/2/reject", "{\"kind\":\"final\",\"reason\":null}", 422, "invalid_reason");
    try f.change(.POST, "/api/v1/admin/applications/2/approve", "{\"role\":\"administrator\"}", 422, "invalid_patch_field");
    const long = "é" ** 1001;
    const body = try std.fmt.allocPrint(std.testing.allocator, "{{\"kind\":\"retryable\",\"reason\":\"{s}\"}}", .{long});
    defer std.testing.allocator.free(body);
    try f.change(.POST, "/api/v1/admin/applications/2/reject", body, 422, "reason_too_long");
    const valid = try std.fmt.allocPrint(std.testing.allocator, "{{\"kind\":\"retryable\",\"reason\":\" {s} \"}}", .{long[0..2000]});
    defer std.testing.allocator.free(valid);
    try f.change(.POST, "/api/v1/admin/applications/2/reject", valid, 204, null);
    try f.expectSql("SELECT octet_length(decision_reason)::text FROM applications WHERE user_id=2", "2000");
}

test "admin_routes_test audit failures rollback decisions edits credentials revocations and CSRF" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.sql("ALTER TABLE audit_log ADD CONSTRAINT fail_task8 CHECK (false)");
    const decision_token = try f.csrf();
    var failed = try f.mutate(.POST, "/api/v1/admin/applications/2/approve", "{}", &decision_token);
    defer failed.deinit();
    try expectError(&failed, 500, "internal_error");
    try f.expectSql("SELECT status::text FROM applications WHERE user_id=2", "pending");
    try f.sql("ALTER TABLE audit_log DROP CONSTRAINT fail_task8");
    var success = try f.mutate(.POST, "/api/v1/admin/applications/2/approve", "{}", &decision_token);
    defer success.deinit();
    try std.testing.expectEqual(@as(u16, 204), success.status);
    try f.sql("INSERT INTO password_credentials (user_id,password_hash) VALUES (2,'stale-secret')");
    try f.sql("ALTER TABLE audit_log ADD CONSTRAINT fail_task8 CHECK (action <> 'user_banned')");
    const token = try f.csrf();
    const patch = "{\"minecraft_nickname\":\"NewName\",\"discord_id\":\"623456789012345678\",\"client_type\":\"cracked\",\"status\":\"banned\",\"reason\":\"No\"}";
    var edit = try f.mutate(.PATCH, "/api/v1/admin/users/2", patch, &token);
    defer edit.deinit();
    try expectError(&edit, 500, "internal_error");
    try f.expectSql("SELECT discord_id FROM users WHERE id=2", "423456789012345678");
    try f.expectSql("SELECT minecraft_nickname || ':' || client_type || ':' || status FROM applications WHERE user_id=2", "Subject_Name:licensed:approved");
    try f.expectSql("SELECT count(*) FROM password_credentials WHERE user_id=2", "1");
    try f.expectSql("SELECT count(*) FROM web_sessions WHERE user_id=2 AND revoked_at IS NULL", "2");
    try f.expectSql("SELECT count(*) FROM audit_log", "2");
    try f.sql("ALTER TABLE audit_log DROP CONSTRAINT fail_task8");
    var retry = try f.mutate(.PATCH, "/api/v1/admin/users/2", patch, &token);
    defer retry.deinit();
    try std.testing.expectEqual(@as(u16, 204), retry.status);
    var replay = try f.mutate(.PATCH, "/api/v1/admin/users/3", "{\"minecraft_nickname\":\"Another\"}", &token);
    defer replay.deinit();
    try expectError(&replay, 403, "csrf_token_invalid");
    try f.expectSql("SELECT count(*) FROM password_credentials WHERE user_id=2", "0");
    try f.expectSql("SELECT count(*) FROM web_sessions WHERE user_id=2 AND revoked_at IS NULL", "0");
    try f.expectSql("SELECT count(*) FROM audit_log", "7");
}

const Worker = struct {
    server: *http.Server,
    request: http.Request,
    status: u16 = 0,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *Worker) void {
        defer self.done.store(true, .release);
        var result = self.server.dispatch(self.request) catch return;
        defer result.deinit();
        self.status = result.status;
    }
};

fn execute(pool: *db.Pool, sql: []const u8) !void {
    var result = try pool.query(sql, &.{});
    result.deinit();
}

// wait on an observed database condition, not a timing guess. Tests use separate connections.
fn waitForLock(pool: *db.Pool, worker: *Worker, advisory: bool) !void {
    const deadline = std.time.milliTimestamp() + 15000;
    while (std.time.milliTimestamp() < deadline) {
        if (worker.done.load(.acquire)) return;
        var result = try pool.query(if (advisory)
            "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname=current_database() AND wait_event='advisory')"
        else
            "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND wait_event<>'advisory')", &.{});
        const waiting = std.mem.eql(u8, result.value(0, 0), "t");
        result.deinit();
        if (waiting) return;
        std.time.sleep(std.time.ns_per_ms);
    }
    return error.LockWaitTimeout;
}

fn raceExchange(_: *anyopaque, _: []const u8, _: []const u8) ![]const u8 {
    return "unused-access-token";
}
fn raceIdentity(_: *anyopaque, _: []const u8) !discord.DiscordIdentity {
    return .{ .id = "423456789012345678", .username = "Previous owner", .global_name = "Previous name", .avatar = "previous-avatar" };
}

test "admin_routes_test in-flight old OAuth callback cannot issue a live session after Discord relink" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var callback_pool = try db.Pool.open(std.testing.allocator, f.database.database_url);
    defer callback_pool.close();
    var control = try db.Pool.open(std.testing.allocator, f.database.database_url);
    defer control.close();
    var provider = discord.DiscordService.init(std.testing.allocator, &callback_pool, &f.loaded, .{ .authorization_endpoint = "http://unused", .context = &f.context, .exchange = raceExchange, .identity = raceIdentity });
    var router = try routes.Router.init(std.testing.allocator, &provider, &f.loaded, &f.resolver);
    defer router.deinit();
    var server = http.Server.init(std.testing.allocator);
    defer server.deinit();
    try routes.register(&server, &router);
    var login = try provider.beginLogin(null);
    defer login.deinit(std.testing.allocator);
    const target = try std.fmt.allocPrint(std.testing.allocator, "/api/v1/auth/discord/callback?code=unused&state={s}", .{login.state});
    defer std.testing.allocator.free(target);
    const binding_cookie = try std.fmt.allocPrint(std.testing.allocator, "mine_oauth={s}", .{login.browser_binding});
    defer {
        std.crypto.utils.secureZero(u8, binding_cookie);
        std.testing.allocator.free(binding_cookie);
    }
    const token = try f.csrf();
    const patch = "{\"discord_id\":\"623456789012345678\"}";
    try execute(&control, "CREATE FUNCTION task8_gate() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_advisory_xact_lock(888); RETURN NEW; END $$; CREATE TRIGGER task8_gate BEFORE INSERT ON web_sessions FOR EACH ROW EXECUTE FUNCTION task8_gate()");
    try execute(&control, "SELECT pg_advisory_lock(888)");
    var callback = Worker{ .server = &server, .request = .{ .method = .GET, .target = target, .cookie = binding_cookie } };
    const callback_thread = try std.Thread.spawn(.{}, Worker.run, .{&callback});
    defer callback_thread.join();
    // always unblock before joining even when an assertion fails.
    defer execute(&control, "SELECT pg_advisory_unlock_all()") catch {};
    try waitForLock(&control, &callback, true);
    var edit = Worker{ .server = &f.server, .request = .{ .method = .PATCH, .target = "/api/v1/admin/users/2", .cookie = f.cookie, .csrf_token = &token, .body = patch, .content_type = "application/json", .content_length = patch.len } };
    const edit_thread = try std.Thread.spawn(.{}, Worker.run, .{&edit});
    defer edit_thread.join();
    defer execute(&control, "SELECT pg_advisory_unlock_all()") catch {};
    try waitForLock(&control, &edit, false);
    try execute(&control, "SELECT pg_advisory_unlock(888)");
    while (!callback.done.load(.acquire) or !edit.done.load(.acquire)) std.Thread.yield() catch {};
    try std.testing.expectEqual(@as(u16, 302), callback.status);
    try std.testing.expectEqual(@as(u16, 204), edit.status);
    try f.expectSql("SELECT count(*) FROM web_sessions WHERE user_id=2 AND revoked_at IS NULL", "0");
    try f.expectSql("SELECT discord_id || ':' || discord_username FROM users WHERE id=2", "623456789012345678:");
}

test "admin_routes_test concurrent own password mutation and admin ban have consistent lock ordering" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.sql("UPDATE applications SET status='approved',client_type='cracked' WHERE user_id=2");
    try f.sql("INSERT INTO password_credentials (user_id,password_hash) VALUES (2,'stale-secret')");
    var account_pool = try db.Pool.open(std.testing.allocator, f.database.database_url);
    defer account_pool.close();
    var control = try db.Pool.open(std.testing.allocator, f.database.database_url);
    defer control.close();
    var provider = discord.DiscordService.init(std.testing.allocator, &account_pool, &f.loaded, .{ .authorization_endpoint = "http://unused", .context = &f.context, .exchange = unusedExchange, .identity = unusedIdentity });
    var router = try routes.Router.init(std.testing.allocator, &provider, &f.loaded, &f.resolver);
    defer router.deinit();
    var server = http.Server.init(std.testing.allocator);
    defer server.deinit();
    try routes.register(&server, &router);
    var service = auth.AuthService.init(std.testing.allocator, &account_pool, &f.loaded);
    var session = try service.createSession(2);
    defer session.deinit(std.testing.allocator);
    const cookie = try std.fmt.allocPrint(std.testing.allocator, "mine_session={s}", .{session.session_token});
    defer std.testing.allocator.free(cookie);
    const token = try f.csrf();
    try execute(&control, "CREATE FUNCTION task8_gate() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.user_id=2 AND NEW.revoked_at IS NULL THEN PERFORM pg_advisory_xact_lock(889); END IF; RETURN NEW; END $$; CREATE TRIGGER task8_gate BEFORE UPDATE ON web_sessions FOR EACH ROW EXECUTE FUNCTION task8_gate()");
    try execute(&control, "SELECT pg_advisory_lock(889)");
    const password = "{\"password\":\"blue-harbor-falcon-2026\"}";
    var own = Worker{ .server = &server, .request = .{ .method = .POST, .target = "/api/v1/account/password", .cookie = cookie, .csrf_token = &session.csrf_token, .body = password, .content_type = "application/json", .content_length = password.len } };
    const own_thread = try std.Thread.spawn(.{}, Worker.run, .{&own});
    defer own_thread.join();
    defer execute(&control, "SELECT pg_advisory_unlock_all()") catch {};
    try waitForLock(&control, &own, true);
    const patch = "{\"status\":\"banned\",\"reason\":\"No\"}";
    var edit = Worker{ .server = &f.server, .request = .{ .method = .PATCH, .target = "/api/v1/admin/users/2", .cookie = f.cookie, .csrf_token = &token, .body = patch, .content_type = "application/json", .content_length = patch.len } };
    const edit_thread = try std.Thread.spawn(.{}, Worker.run, .{&edit});
    defer edit_thread.join();
    defer execute(&control, "SELECT pg_advisory_unlock_all()") catch {};
    try waitForLock(&control, &edit, false);
    try execute(&control, "SELECT pg_advisory_unlock(889)");
    while (!own.done.load(.acquire) or !edit.done.load(.acquire)) std.Thread.yield() catch {};
    try std.testing.expectEqual(@as(u16, 204), own.status);
    // The competing password commit advances the subject revision. Admin must
    // reload rather than silently replay stale prepared evidence.
    try std.testing.expectEqual(@as(u16, 409), edit.status);
    try f.change(.PATCH, "/api/v1/admin/users/2", patch, 204, null);
    try f.expectSql("SELECT count(*) FROM web_sessions WHERE user_id=2 AND revoked_at IS NULL", "0");
}
