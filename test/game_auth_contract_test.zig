const std = @import("std");
const service = @import("game_auth_service");
const fixture = @import("contract_repository");
const repo = @import("game_auth_repository");
const a = std.testing.allocator;
fn init() service.GameAuthService {
    return .{ .allocator = a, .repository = .{ .allocator = a }, .limiter = service.AttemptLimiter.init(a) };
}
fn exact(want: []const u8, got: []u8) !void {
    defer a.free(got);
    try std.testing.expectEqualStrings(want, got);
}
fn failure(want: anyerror, result: anyerror![]u8) !void {
    if (result) |unexpected| {
        defer a.free(unexpected);
        return error.ExpectedFailure;
    } else |err| try std.testing.expectEqual(want, err);
}
test "game-auth policy is outcome only including unbound licensed" {
    var s = init();
    defer s.deinit();
    if (comptime @hasDecl(service.GameAuthService, "nicknamePolicy")) {
        for ([_]fixture.Policy{ .denied, .cracked, .licensed }, [_][]const u8{ "{\"outcome\":\"denied\"}", "{\"outcome\":\"cracked\"}", "{\"outcome\":\"licensed\"}" }) |policy, want| {
            s.repository.policy = policy;
            try exact(want, try s.nicknamePolicy("Player"));
        }
    } else try std.testing.expect(false);
}
test "game-auth unchanged omits identities" {
    var s = init();
    defer s.deinit();
    try exact("{\"outcome\":\"unchanged\",\"whitelist_version\":42}", try s.whitelist(42));
}
test "game-auth empty snapshot is authoritative replacement" {
    var s = init();
    defer s.deinit();
    try exact("{\"outcome\":\"snapshot\",\"whitelist_version\":42,\"identities\":[]}", try s.whitelist(null));
}
test "game-auth populated snapshot exposes only playable projection" {
    var s = init();
    defer s.deinit();
    s.repository.populated = true;
    try exact("{\"outcome\":\"snapshot\",\"whitelist_version\":42,\"identities\":[{\"nickname\":\"Player\",\"client_type\":\"cracked\",\"uuid\":\"a01e3843-e521-3998-958a-f459800e4d11\"}]}", try s.whitelist(null));
}
test "game-auth login denial contains no identity or token" {
    var s = init();
    defer s.deinit();
    try exact("{\"outcome\":\"deny\",\"whitelist_version\":42}", try s.crackedLogin("test", "{\"nickname\":\"Player\",\"password\":\"PASSWORD_SENTINEL\"}"));
    try exact("{\"outcome\":\"deny\",\"whitelist_version\":42}", try s.premiumVerified("test", "{\"nickname\":\"Player\",\"mojang_uuid\":\"UUID_SENTINEL\"}"));
}
fn allowed(body: []u8, outcome: []const u8) !void {
    defer a.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(usize, 5), obj.count());
    try std.testing.expectEqualStrings(outcome, obj.get("outcome").?.string);
    try std.testing.expectEqualStrings(fixture.uuid, obj.get("uuid").?.string);
    try std.testing.expectEqual(@as(i64, 1730000000), obj.get("expires_at").?.integer);
    try std.testing.expectEqual(@as(i64, 42), obj.get("whitelist_version").?.integer);
    const lease = obj.get("lease").?;
    try std.testing.expect(lease == .string);
    try std.testing.expectEqualStrings(fixture.token, lease.string);
    for (lease.string) |c| try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
}
test "game-auth allow uses hex string not integer array" {
    var s = init();
    defer s.deinit();
    s.repository.allow = true;
    try allowed(try s.crackedLogin("test", "{\"nickname\":\"Player\",\"password\":\"PASSWORD_SENTINEL\"}"), "allow");
    try allowed(try s.premiumVerified("test", "{\"nickname\":\"Player\",\"mojang_uuid\":\"UUID_SENTINEL\"}"), "allow");
}
test "game-auth lease round trips as session input and continue string" {
    var s = init();
    defer s.deinit();
    s.repository.allow = true;
    const login = try s.crackedLogin("test", "{\"nickname\":\"Player\",\"password\":\"PASSWORD_SENTINEL\"}");
    defer a.free(login);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, login, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("lease").? == .string);
    const input = try std.json.stringifyAlloc(a, .{ .lease = parsed.value.object.get("lease").?.string }, .{});
    defer a.free(input);
    try allowed(try s.sessionCheck("test", input), "continue");
}
test "game-auth disconnect contains only outcome and version" {
    var s = init();
    defer s.deinit();
    try exact("{\"outcome\":\"disconnect\",\"whitelist_version\":42}", try s.sessionCheck("test", "{\"lease\":\"INVALID_TOKEN_SENTINEL\"}"));
}
test "game-auth storage failures are failures not ordinary decisions" {
    var s = init();
    defer s.deinit();
    s.repository.storage_failure = true;
    try failure(error.StorageUnavailable, s.crackedLogin("test", "{\"nickname\":\"Player\",\"password\":\"PASSWORD_SENTINEL\"}"));
    try failure(error.StorageUnavailable, s.premiumVerified("test", "{\"nickname\":\"Player\",\"mojang_uuid\":\"UUID_SENTINEL\"}"));
    try failure(error.StorageUnavailable, s.sessionCheck("test", "{\"lease\":\"TOKEN_SENTINEL\"}"));
    try failure(error.StorageUnavailable, s.whitelist(null));
    try failure(error.StorageUnavailable, s.nicknamePolicy("Player"));
}
test "game-auth audit failure cannot produce allow" {
    var s = init();
    defer s.deinit();
    s.repository.allow = true;
    s.repository.audit_failure = true;
    try failure(error.AuditUnavailable, s.crackedLogin("test", "{\"nickname\":\"Player\",\"password\":\"PASSWORD_SENTINEL\"}"));
    try failure(error.AuditUnavailable, s.premiumVerified("test", "{\"nickname\":\"Player\",\"mojang_uuid\":\"UUID_SENTINEL\"}"));
    try failure(error.AuditUnavailable, s.sessionCheck("test", "{\"lease\":\"" ++ fixture.token ++ "\"}"));
    s.repository.allow = false;
    try failure(error.AuditUnavailable, s.crackedLogin("test", "{\"nickname\":\"Player\",\"password\":\"PASSWORD_SENTINEL\"}"));
    try failure(error.AuditUnavailable, s.sessionCheck("test", "{\"lease\":\"TOKEN_SENTINEL\"}"));
}
test "game-auth issue outage differs from stale binding denial" {
    var s = init();
    defer s.deinit();
    s.repository.allow = true;
    s.repository.issue_failure = true;
    try failure(error.StorageUnavailable, s.crackedLogin("test", "{\"nickname\":\"Player\",\"password\":\"PASSWORD_SENTINEL\"}"));
    s.repository.issue_failure = false;
    s.repository.stale_binding = true;
    try exact("{\"outcome\":\"deny\",\"whitelist_version\":42}", try s.crackedLogin("test", "{\"nickname\":\"Player\",\"password\":\"PASSWORD_SENTINEL\"}"));
}
test "game-auth audit categories never interpolate sensitive request values" {
    var s = init();
    defer s.deinit();
    try exact("{\"outcome\":\"deny\",\"whitelist_version\":42}", try s.crackedLogin("test", "{\"nickname\":\"Player\",\"password\":\"PASSWORD_SENTINEL_HASH_RAW_BODY\"}"));
    try std.testing.expectEqualStrings("deny", s.repository.last_audit_outcome);
    try std.testing.expectEqualStrings("cracked_login", s.repository.last_audit_reason);
    try exact("{\"outcome\":\"disconnect\",\"whitelist_version\":42}", try s.sessionCheck("test", "{\"lease\":\"TOKEN_SENTINEL\"}"));
    try std.testing.expectEqualStrings("disconnect", s.repository.last_audit_outcome);
    try std.testing.expectEqualStrings("invalid_or_expired_lease", s.repository.last_audit_reason);
}
test "game-auth offline UUID preserves display case" {
    if (comptime @hasDecl(repo, "offlineUuid")) {
        const upper = try repo.offlineUuid(a, "Player");
        defer a.free(upper);
        const lower = try repo.offlineUuid(a, "player");
        defer a.free(lower);
        try std.testing.expectEqualStrings("a01e3843-e521-3998-958a-f459800e4d11", upper);
        try std.testing.expect(!std.mem.eql(u8, upper, lower));
    } else try std.testing.expect(false);
}
test "game-auth repository policy denies unknown and unapproved names" {
    if (comptime @hasDecl(repo, "policyFor")) {
        try std.testing.expectEqual(repo.Policy.denied, try repo.policyFor(null, null));
        for ([_][]const u8{ "pending", "rejected_retryable", "rejected_final", "banned" }) |status| {
            try std.testing.expectEqual(repo.Policy.denied, try repo.policyFor("cracked", status));
            try std.testing.expectEqual(repo.Policy.denied, try repo.policyFor("licensed", status));
        }
        try std.testing.expectEqual(repo.Policy.cracked, try repo.policyFor("cracked", "approved"));
        try std.testing.expectEqual(repo.Policy.licensed, try repo.policyFor("licensed", "approved"));
        try std.testing.expectError(error.InvalidClientType, repo.policyFor("unknown", "approved"));
    } else try std.testing.expect(false);
}
