const std = @import("std");
const c = @cImport({
    @cInclude("stdlib.h");
});
const config = @import("config");
const auth = @import("auth");
const db = @import("db_pool");
const migrations = @import("migrations");
const postgres = @import("postgres");

const valid_session_key = "0123456789abcdef0123456789abcdef";

fn setEnvironment(name: [:0]const u8, value: [:0]const u8) !void {
    try std.testing.expectEqual(@as(c_int, 0), c.setenv(name.ptr, value.ptr, 1));
}

fn setEnvironmentSlice(name: [:0]const u8, value: []const u8) !void {
    const value_z = try std.testing.allocator.dupeZ(u8, value);
    defer std.testing.allocator.free(value_z);
    try setEnvironment(name, value_z);
}

fn setValidEnvironment() !void {
    try setEnvironment("DATABASE_URL", "postgresql://unused");
    try setEnvironment("HTTP_LISTEN_ADDRESS", "127.0.0.1:8088");
    try setEnvironment("PUBLIC_ORIGIN", "http://127.0.0.1:3000");
    try setEnvironment("DISCORD_CLIENT_ID", "test-client-id");
    try setEnvironment("DISCORD_CLIENT_SECRET", "test-client-secret");
    try setEnvironment("DISCORD_REDIRECT_URI", "http://127.0.0.1:3000/api/v1/auth/discord/callback");
    try setEnvironment("SESSION_SIGNING_KEY", valid_session_key);
    try setEnvironment("ADMIN_DISCORD_IDS", "123456789012345678");
    try setEnvironment("MODERATOR_DISCORD_IDS", "223456789012345678");
    try setEnvironment("DEVELOPMENT_MODE", "true");
}

test "auth_service_test Config.load rejects an empty session signing key" {
    try setValidEnvironment();
    try setEnvironment("SESSION_SIGNING_KEY", "");
    try std.testing.expectError(error.InvalidSessionSigningKey, config.Config.load(std.testing.allocator));
}

test "auth_service_test Config.load rejects a too-short session signing key" {
    try setValidEnvironment();
    try setEnvironment("SESSION_SIGNING_KEY", "0123456789abcdef0123456789abcde");
    try std.testing.expectError(error.InvalidSessionSigningKey, config.Config.load(std.testing.allocator));
}

test "auth_service_test Config.load rejects malformed administrator Discord IDs" {
    try setValidEnvironment();
    try setEnvironment("ADMIN_DISCORD_IDS", "123456789012345678,not-a-discord-id");
    try std.testing.expectError(error.InvalidDiscordId, config.Config.load(std.testing.allocator));
}

test "auth_service_test Config.load rejects duplicate administrator Discord IDs" {
    try setValidEnvironment();
    try setEnvironment("ADMIN_DISCORD_IDS", "123456789012345678, 123456789012345678");
    try std.testing.expectError(error.DuplicateDiscordId, config.Config.load(std.testing.allocator));
}

test "auth_service_test Config.load rejects malformed public-origin authorities and ports" {
    const invalid_origins = [_][]const u8{
        "http://example.com:bad",
        "http://example.com:65536",
        "http://[::1",
        "http://user@example.com",
        "http://example.com/path",
    };
    for (invalid_origins) |invalid_origin| {
        try setValidEnvironment();
        try setEnvironmentSlice("PUBLIC_ORIGIN", invalid_origin);
        try std.testing.expectError(error.InvalidPublicOrigin, config.Config.load(std.testing.allocator));
    }
}

test "auth_service_test Config.load rejects permissive-parser public-origin authority suffixes" {
    const cases = [_]struct { origin: []const u8, callback: []const u8 }{
        .{ .origin = "https://[::1]junk", .callback = "https://[::1]/callback" },
        .{ .origin = "https://example.com:4_43", .callback = "https://example.com/callback" },
    };
    for (cases) |case| {
        try setValidEnvironment();
        try setEnvironmentSlice("PUBLIC_ORIGIN", case.origin);
        try setEnvironmentSlice("DISCORD_REDIRECT_URI", case.callback);
        try std.testing.expectError(error.InvalidPublicOrigin, config.Config.load(std.testing.allocator));
    }
}

test "auth_service_test Config.load rejects permissive-parser callback authority suffixes" {
    const cases = [_]struct { origin: []const u8, callback: []const u8 }{
        .{ .origin = "https://[::1]", .callback = "https://[::1]junk/callback" },
        .{ .origin = "https://example.com", .callback = "https://example.com:4_43/callback" },
    };
    for (cases) |case| {
        try setValidEnvironment();
        try setEnvironmentSlice("PUBLIC_ORIGIN", case.origin);
        try setEnvironmentSlice("DISCORD_REDIRECT_URI", case.callback);
        try std.testing.expectError(error.InvalidDiscordRedirectUri, config.Config.load(std.testing.allocator));
    }
}

test "auth_service_test Config.load rejects malformed callbacks and callbacks outside the public origin" {
    const invalid_callbacks = [_][]const u8{
        "http://127.0.0.1:bad/api/v1/auth/discord/callback",
        "http://127.0.0.1:3000",
        "http://127.0.0.1:3001/api/v1/auth/discord/callback",
        "https://127.0.0.1:3000/api/v1/auth/discord/callback",
        "http://user@127.0.0.1:3000/api/v1/auth/discord/callback",
    };
    for (invalid_callbacks) |invalid_callback| {
        try setValidEnvironment();
        try setEnvironmentSlice("DISCORD_REDIRECT_URI", invalid_callback);
        try std.testing.expectError(error.InvalidDiscordRedirectUri, config.Config.load(std.testing.allocator));
    }
}

test "auth_service_test Config.load rejects an invalid public origin" {
    try setValidEnvironment();
    try setEnvironment("DEVELOPMENT_MODE", "false");
    try setEnvironment("PUBLIC_ORIGIN", "https://");
    try setEnvironment("DISCORD_REDIRECT_URI", "https:///api/v1/auth/discord/callback");
    try std.testing.expectError(error.InvalidPublicOrigin, config.Config.load(std.testing.allocator));
}

test "auth_service_test Config.load rejects overlapping administrator and moderator Discord IDs" {
    try setValidEnvironment();
    try setEnvironment("MODERATOR_DISCORD_IDS", "123456789012345678");
    try std.testing.expectError(error.OverlappingRoleDiscordId, config.Config.load(std.testing.allocator));
}

test "auth_service_test session authentication dynamically resolves administrator role and enforces CSRF and revocation" {
    const admin_database_url = std.posix.getenv("TEST_DATABASE_URL") orelse return error.MissingTestDatabaseUrl;
    var test_database = try postgres.TestDatabase.create(std.testing.allocator, admin_database_url);
    defer test_database.deinit();
    try migrations.apply(&test_database.pool);

    try setValidEnvironment();
    var loaded_config = try config.Config.load(std.testing.allocator);
    defer loaded_config.deinit();

    var insert_user = try test_database.pool.query(
        "INSERT INTO users (discord_id, discord_username) VALUES ($1, $2) RETURNING id",
        &.{ "123456789012345678", "administrator" },
    );
    defer insert_user.deinit();
    const user_id = try std.fmt.parseInt(i64, insert_user.value(0, 0), 10);

    var service = auth.AuthService.init(std.testing.allocator, &test_database.pool, &loaded_config);
    var issued = try service.createSession(user_id);
    defer issued.deinit(std.testing.allocator);

    const request = auth.Request{ .session_token = &issued.session_token, .csrf_token = null };
    const actor = try service.authenticate(request);
    try std.testing.expectEqual(user_id, actor.user_id);
    try std.testing.expectEqual(.administrator, actor.role);

    try std.testing.expectError(error.CsrfTokenRequired, service.requireCsrf(request, actor));
    const wrong_csrf_request = auth.Request{ .session_token = &issued.session_token, .csrf_token = "wrong-csrf-token" };
    try std.testing.expectError(error.CsrfTokenInvalid, service.requireCsrf(wrong_csrf_request, actor));
    const csrf_request = auth.Request{ .session_token = &issued.session_token, .csrf_token = &issued.csrf_token };
    try service.requireCsrf(csrf_request, actor);

    try service.revokeUserSessions(user_id);
    try std.testing.expectError(error.SessionNotFound, service.authenticate(request));
}
