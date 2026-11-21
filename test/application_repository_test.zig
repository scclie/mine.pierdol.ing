const std = @import("std");
const db = @import("db_pool");
const domain = @import("domain");
const admission = domain.licensed_admission;
const Uuid = domain.mojang_uuid.Uuid;
const applications = @import("applications");
const postgres = @import("postgres");
const migrations = @import("migrations");
const allocator = std.testing.allocator;
const first = "12345678-1234-1234-1234-123456789abc";
const second = "22345678-1234-1234-1234-123456789abc";
const now = 20 * std.time.ns_per_s;

fn fixture() !postgres.TestDatabase {
    var database = try postgres.TestDatabase.create(allocator, std.posix.getenv("TEST_DATABASE_URL") orelse return error.TestDatabaseUrlNotConfigured);
    errdefer database.deinit();
    try migrations.apply(&database.pool);
    try exec(&database.pool,
        \\INSERT INTO users (discord_id,discord_username) VALUES ('fixture-1','one'),('fixture-2','two'),('fixture-3','three');
        \\INSERT INTO applications (user_id,minecraft_nickname,minecraft_nickname_normalized,client_type,about_me,discovery_source)
        \\VALUES (1,'LicensedOne','licensedone','licensed','fixture','test'),(2,'LicensedTwo','licensedtwo','licensed','fixture','test');
        \\INSERT INTO password_credentials (user_id,password_hash) VALUES (1,'non-secret-test-placeholder');
        \\INSERT INTO web_sessions (id,user_id,token_hash,csrf_token_hash,expires_at)
        \\VALUES ('33333333-1234-1234-1234-123456789abc',1,'fixture-token','fixture-csrf',now()+interval '1 hour');
    );
    return database;
}

fn exec(pool: *db.Pool, sql: []const u8) !void {
    var result = try pool.query(sql, &.{});
    result.deinit();
}

fn locked(transaction: *db.Transaction) !admission.Snapshot {
    var owners = try transaction.query("SELECT id FROM users WHERE id IN (1,2) ORDER BY id FOR UPDATE", &.{});
    owners.deinit();
    return applications.readLockedAdmissionSnapshot(transaction, 1);
}

fn prepared(snapshot: admission.Snapshot) !admission.Prepared {
    return .{ .expected = snapshot, .intent = .{ .operation = .approve }, .observation = .{
        .requested = try domain.nickname.validateNickname("LicensedOne"),
        .returned = try domain.nickname.validateNickname("licensedone"),
        .uuid = try Uuid.parseAdmin(first),
        .observed_ns = now,
    } };
}

fn validate(snapshot: admission.Snapshot, evidence: admission.Prepared, timestamp: u64) !void {
    _ = try applications.validatePrepared(snapshot, evidence, timestamp);
}

fn readSnapshot(repository: *applications.ApplicationRepository, user_id: i64) !void {
    _ = try repository.readAdmissionSnapshot(user_id);
}

// safe projections compare rollback state without exposing password/session values.
fn state(pool: *db.Pool) ![]u8 {
    var result = try pool.query(
        \\SELECT jsonb_build_object(
        \\ 'applications',(SELECT jsonb_agg(to_jsonb(a) ORDER BY user_id) FROM applications a),
        \\ 'identities',(SELECT jsonb_agg(to_jsonb(g) ORDER BY user_id) FROM game_identities g),
        \\ 'credentials',(SELECT jsonb_agg(jsonb_build_array(user_id,changed_at,password_hash='non-secret-test-placeholder') ORDER BY user_id) FROM password_credentials),
        \\ 'sessions',(SELECT jsonb_agg(jsonb_build_array(user_id,revoked_at,csrf_token_hash='fixture-csrf'::bytea) ORDER BY user_id) FROM web_sessions),
        \\ 'audits',(SELECT jsonb_agg(to_jsonb(a) ORDER BY id) FROM audit_log a),
        \\ 'revisions',(SELECT jsonb_agg(jsonb_build_array(id,application_revision) ORDER BY id) FROM users),
        \\ 'cursor',(SELECT version FROM game_auth_whitelist_state))::text
    , &.{});
    defer result.deinit();
    return allocator.dupe(u8, result.value(0, 0));
}

fn expectState(pool: *db.Pool, before: []const u8) !void {
    const after = try state(pool);
    defer allocator.free(after);
    // Avoid printing fixture projections on failure.
    try std.testing.expect(std.mem.eql(u8, before, after));
}

fn counters(pool: *db.Pool) ![4]u64 {
    var result = try pool.query("SELECT u.application_revision,g.authentication_generation,s.version,(SELECT count(*) FROM audit_log) FROM users u JOIN game_identities g ON g.user_id=u.id CROSS JOIN game_auth_whitelist_state s WHERE u.id=1", &.{});
    defer result.deinit();
    var values: [4]u64 = undefined;
    for (&values, 0..) |*value, index| value.* = try std.fmt.parseInt(u64, result.value(0, index), 10);
    return values;
}

test "application_repository_test lifecycle owned snapshot distinguishes absence" {
    var database = try fixture();
    defer database.deinit();
    var repository = applications.ApplicationRepository.init(&database.pool);
    const snapshot = try repository.readAdmissionSnapshot(1);
    const absent = try repository.readAdmissionSnapshot(3);
    try std.testing.expect(absent.application == null and absent.identity_id == null and absent.uuid == null);
    try exec(&database.pool, "DELETE FROM game_identities WHERE user_id=1");
    const missing = try repository.readAdmissionSnapshot(1);
    try std.testing.expect(missing.application != null and missing.identity_id == null);
    try std.testing.expectEqualStrings("LicensedOne", snapshot.application.?.nickname.display());
    try std.testing.expect(snapshot.identity_id != null and snapshot.uuid == null);
    try std.testing.expectError(error.UserNotFound, readSnapshot(&repository, 999));
    var transaction = try database.pool.begin();
    defer transaction.rollback() catch {};
    const current = try locked(&transaction);
    try std.testing.expectError(error.GameIdentityMissing, validate(current, try prepared(current), now));
}

test "application_repository_test lifecycle validates evidence policy and fixed snapshot fields" {
    var database = try fixture();
    defer database.deinit();
    var repository = applications.ApplicationRepository.init(&database.pool);
    const snapshot = try repository.readAdmissionSnapshot(1);
    const valid = try prepared(snapshot);
    const decision = try applications.validatePrepared(snapshot, valid, now);
    try std.testing.expect(decision.lookup_required and decision.final.status == .approved);
    try std.testing.expect((try admission.binding(snapshot, decision, valid.observation)).?.eql(try Uuid.parseAdmin(first)));
    var invalid = valid;
    invalid.expected = null;
    try std.testing.expectError(error.IdentityChanged, validate(snapshot, invalid, now));
    invalid = valid;
    invalid.observation = null;
    try std.testing.expectError(error.MojangObservationRequired, validate(snapshot, invalid, now));
    invalid = valid;
    invalid.observation.?.observed_ns = now + 1;
    try std.testing.expectError(error.IdentityChanged, validate(snapshot, invalid, now));
    invalid.observation.?.observed_ns = now - 10 * std.time.ns_per_s - 1;
    try std.testing.expectError(error.IdentityChanged, validate(snapshot, invalid, now));
    invalid.observation.?.observed_ns += 1;
    _ = try applications.validatePrepared(snapshot, invalid, now);
    invalid = valid;
    invalid.observation.?.requested = try domain.nickname.validateNickname("OtherName");
    try std.testing.expectError(error.IdentityChanged, validate(snapshot, invalid, now));
    invalid = valid;
    invalid.observation.?.returned = try domain.nickname.validateNickname("OtherName");
    try std.testing.expectError(error.IdentityChanged, validate(snapshot, invalid, now));
    var bound = snapshot;
    bound.uuid = try Uuid.parseAdmin(first);
    _ = try applications.validatePrepared(bound, try prepared(bound), now);
    bound.uuid = try Uuid.parseAdmin(second);
    invalid = try prepared(bound);
    try std.testing.expectError(error.LicensedMojangUuidMismatch, validate(bound, invalid, now));
    inline for (.{ "revision", "application", "identity_id", "uuid", "nickname", "client_type", "status" }) |field| {
        var changed = snapshot;
        if (comptime std.mem.eql(u8, field, "revision")) changed.revision += 1;
        if (comptime std.mem.eql(u8, field, "application")) changed.application = null;
        if (comptime std.mem.eql(u8, field, "identity_id")) changed.identity_id = snapshot.identity_id.? + 1;
        if (comptime std.mem.eql(u8, field, "uuid")) changed.uuid = try Uuid.parseAdmin(first);
        if (comptime std.mem.eql(u8, field, "nickname")) changed.application.?.nickname = try domain.nickname.validateNickname("OtherName");
        if (comptime std.mem.eql(u8, field, "client_type")) changed.application.?.client_type = .cracked;
        if (comptime std.mem.eql(u8, field, "status")) changed.application.?.status = .approved;
        try std.testing.expectError(error.IdentityChanged, validate(changed, valid, now));
    }
    const manual = admission.Prepared{ .expected = snapshot, .intent = .{ .operation = .edit, .uuid = .{ .set = try Uuid.parseAdmin(first) }, .confirmed_override = true, .has_reason = true }, .observation = null };
    _ = try applications.validatePrepared(snapshot, manual, now);
    var mandatory = manual;
    mandatory.intent.operation = .approve;
    try std.testing.expectError(error.MojangObservationRequired, validate(snapshot, mandatory, now));
}

test "application_repository_test lifecycle competing commits and ABA survive rejected transaction" {
    const mutations = [_][]const u8{
        "UPDATE applications SET minecraft_nickname='Renamed',minecraft_nickname_normalized='renamed' WHERE user_id=1",
        "UPDATE applications SET status='approved' WHERE user_id=1",
        "UPDATE applications SET client_type='cracked' WHERE user_id=1",
        "SELECT application_set_licensed_uuid(1,'" ++ first ++ "')",
        "DELETE FROM game_identities WHERE user_id=1",
        "DELETE FROM game_identities WHERE user_id=1; INSERT INTO game_identities (user_id) VALUES (1)",
        "UPDATE applications SET client_type='cracked' WHERE user_id=1; UPDATE applications SET client_type='licensed' WHERE user_id=1",
        "UPDATE applications SET status='approved' WHERE user_id=1; UPDATE applications SET status='pending' WHERE user_id=1",
        "manual reaffirmation",
    };
    for (mutations) |mutation| {
        var database = try fixture();
        defer database.deinit();
        var repository = applications.ApplicationRepository.init(&database.pool);
        const reaffirm = std.mem.eql(u8, mutation, "manual reaffirmation");
        if (reaffirm) try exec(&database.pool, "SELECT application_set_licensed_uuid(1,'" ++ first ++ "')");
        const evidence = try prepared(try repository.readAdmissionSnapshot(1));
        var competitor = try db.Pool.open(allocator, database.database_url);
        defer competitor.close();
        if (reaffirm) {
            var competing_transaction = try competitor.begin();
            errdefer competing_transaction.rollback() catch {};
            const competing = try locked(&competing_transaction);
            _ = try applications.validatePrepared(competing, .{ .expected = competing, .intent = .{ .operation = .edit, .uuid = .{ .set = try Uuid.parseAdmin(first) }, .confirmed_override = true, .has_reason = true }, .observation = null }, now);
            try applications.writeLicensedBinding(&competing_transaction, allocator, 2, 1, competing.uuid, competing.uuid, .manual_admin, "competing reaffirmation", true);
            try competing_transaction.commit();
        } else try exec(&competitor, mutation);
        const before = try state(&database.pool);
        defer allocator.free(before);
        var transaction = try database.pool.begin();
        errdefer transaction.rollback() catch {};
        const current = try locked(&transaction);
        try exec(&database.pool, "UPDATE applications SET about_me='attempt' WHERE user_id=1; UPDATE web_sessions SET revoked_at=now(),csrf_token_hash='attempt' WHERE user_id=1");
        try std.testing.expectError(error.IdentityChanged, validate(current, evidence, now));
        try transaction.rollback();
        try expectState(&database.pool, before);
    }
}

test "application_repository_test lifecycle binding change no-op reaffirm and clear" {
    var database = try fixture();
    defer database.deinit();
    var transaction = try database.pool.begin();
    errdefer transaction.rollback() catch {};
    const current = try locked(&transaction);
    _ = try applications.validatePrepared(current, try prepared(current), now);
    const before = try counters(&database.pool);
    const uuid = try Uuid.parseAdmin(first);
    try applications.writeLicensedBinding(&transaction, allocator, null, 1, null, uuid, .mojang_lookup, "untrusted response", false);
    try transaction.commit();
    const bound = try counters(&database.pool);
    try std.testing.expectEqual(before[0] + 1, bound[0]);
    try std.testing.expectEqual(before[1] + 1, bound[1]);
    try std.testing.expectEqual(before[2] + 1, bound[2]);
    try std.testing.expectEqual(before[3] + 1, bound[3]);
    var audit = try database.pool.query("SELECT old_value->>'source',old_value->'licensed_mojang_uuid'='null'::jsonb,new_value->>'licensed_mojang_uuid',reason,actor_user_id IS NULL FROM audit_log", &.{});
    defer audit.deinit();
    try std.testing.expectEqualStrings("mojang_lookup", audit.value(0, 0));
    try std.testing.expectEqualStrings("t", audit.value(0, 1));
    try std.testing.expectEqualStrings(first, audit.value(0, 2));
    try std.testing.expectEqualStrings("mojang_lookup", audit.value(0, 3));
    try std.testing.expectEqualStrings("t", audit.value(0, 4));
    transaction = try database.pool.begin();
    const automatic = try locked(&transaction);
    _ = try applications.validatePrepared(automatic, .{ .expected = automatic, .intent = .{ .operation = .edit }, .observation = null }, now);
    const unchanged = try state(&database.pool);
    defer allocator.free(unchanged);
    // a no-op must not call even the setter's SQL boundary.
    try exec(&database.pool, "SAVEPOINT no_setter; CREATE OR REPLACE FUNCTION application_set_licensed_uuid(owner_id BIGINT,replacement_uuid UUID) RETURNS TEXT LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'unexpected setter'; END $$");
    try applications.writeLicensedBinding(&transaction, allocator, 2, 1, uuid, uuid, .mojang_lookup, null, false);
    try expectState(&database.pool, unchanged);
    try exec(&database.pool, "ROLLBACK TO SAVEPOINT no_setter");
    try transaction.commit();
    try expectState(&database.pool, unchanged);
    transaction = try database.pool.begin();
    const manual = try locked(&transaction);
    _ = try applications.validatePrepared(manual, .{ .expected = manual, .intent = .{ .operation = .edit, .uuid = .{ .set = uuid }, .confirmed_override = true, .has_reason = true }, .observation = null }, now);
    try applications.writeLicensedBinding(&transaction, allocator, 2, 1, uuid, uuid, .manual_admin, "confirmed fixture", true);
    try transaction.commit();
    const reaffirmed = try counters(&database.pool);
    try std.testing.expectEqual(bound[0] + 1, reaffirmed[0]);
    try std.testing.expectEqual(bound[1], reaffirmed[1]);
    try std.testing.expectEqual(bound[2], reaffirmed[2]);
    try std.testing.expectEqual(bound[3] + 1, reaffirmed[3]);
    var manual_audit = try database.pool.query("SELECT actor_user_id,reason,old_value=new_value FROM audit_log WHERE new_value->>'source'='manual_admin'", &.{});
    defer manual_audit.deinit();
    try std.testing.expectEqualStrings("2", manual_audit.value(0, 0));
    try std.testing.expectEqualStrings("confirmed fixture", manual_audit.value(0, 1));
    try std.testing.expectEqualStrings("t", manual_audit.value(0, 2));
    transaction = try database.pool.begin();
    const licensed = try locked(&transaction);
    _ = try applications.validatePrepared(licensed, .{ .expected = licensed, .intent = .{ .operation = .edit, .client_type = .cracked }, .observation = null }, now);
    try applications.writeLicensedBinding(&transaction, allocator, 2, 1, uuid, null, .cracked_clear, null, false);
    try transaction.commit();
    const cleared = try counters(&database.pool);
    try std.testing.expectEqual(reaffirmed[0] + 1, cleared[0]);
    try std.testing.expectEqual(reaffirmed[1] + 1, cleared[1]);
    try std.testing.expectEqual(reaffirmed[2] + 1, cleared[2]);
    var clear_audit = try database.pool.query("SELECT licensed_mojang_uuid IS NULL,(SELECT new_value->'licensed_mojang_uuid'='null'::jsonb FROM audit_log WHERE new_value->>'source'='cracked_clear') FROM game_identities WHERE user_id=1", &.{});
    defer clear_audit.deinit();
    try std.testing.expectEqualStrings("t", clear_audit.value(0, 0));
    try std.testing.expectEqualStrings("t", clear_audit.value(0, 1));
}

test "application_repository_test lifecycle binding failures roll back earlier writes" {
    const failures = [_]struct { setup: []const u8, expected: anyerror }{
        .{ .setup = "SELECT application_set_licensed_uuid(2,'" ++ first ++ "')", .expected = error.LicensedMojangUuidInUse },
        .{ .setup = "DELETE FROM game_identities WHERE user_id=1", .expected = error.GameIdentityMissing },
        .{ .setup = "CREATE FUNCTION fixture_fail() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fixture audit failure'; END $$; CREATE TRIGGER fixture_fail BEFORE INSERT ON audit_log FOR EACH ROW EXECUTE FUNCTION fixture_fail()", .expected = error.QueryFailed },
        .{ .setup = "CREATE FUNCTION fixture_fail() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE unique_violation USING CONSTRAINT='fixture_unrelated_unique_key'; END $$; CREATE TRIGGER fixture_fail BEFORE UPDATE OF licensed_mojang_uuid ON game_identities FOR EACH ROW EXECUTE FUNCTION fixture_fail()", .expected = error.QueryFailed },
    };
    for (failures) |failure| {
        var database = try fixture();
        defer database.deinit();
        try exec(&database.pool, failure.setup);
        const before = try state(&database.pool);
        defer allocator.free(before);
        var transaction = try database.pool.begin();
        errdefer transaction.rollback() catch {};
        const current = try locked(&transaction);
        if (current.identity_id != null) _ = try applications.validatePrepared(current, try prepared(current), now);
        try exec(&database.pool, "UPDATE applications SET about_me='attempt' WHERE user_id=1; UPDATE password_credentials SET changed_at=now()+interval '1 second' WHERE user_id=1; UPDATE web_sessions SET revoked_at=now(),csrf_token_hash='attempt' WHERE user_id=1");
        try std.testing.expectError(failure.expected, applications.writeLicensedBinding(&transaction, allocator, 2, 1, null, try Uuid.parseAdmin(first), .mojang_lookup, null, false));
        try transaction.rollback();
        try expectState(&database.pool, before);
    }
}
