const std = @import("std");
const db = @import("db_pool");
const migrations = @import("migrations");
const postgres = @import("postgres");
const repository = @import("game_auth_repository");
const service = @import("game_auth_service");
const domain = @import("domain");
const routes = @import("game_auth_routes");
const http = @import("http_server");
const config = @import("config");

comptime {
    std.testing.refAllDecls(repository.Repository);
    std.testing.refAllDecls(service.GameAuthService);
}

fn testDatabase() !postgres.TestDatabase {
    const admin_database_url = std.posix.getenv("TEST_DATABASE_URL") orelse return error.MissingTestDatabaseUrl;
    var database = try postgres.TestDatabase.create(std.testing.allocator, admin_database_url);
    errdefer database.deinit();
    std.debug.print("RESOURCE created database={s} (deferred DROP; runner verifies none remain)\n", .{database.name});
    try migrations.apply(&database.pool);
    return database;
}

fn insertApplication(pool: *db.Pool, nickname: []const u8, canonical: []const u8, client_type: []const u8, status: []const u8) !i64 {
    var user = try pool.query("INSERT INTO users (discord_id,discord_username) VALUES ('100000000000000001','game-auth-test') RETURNING id", &.{});
    defer user.deinit();
    const user_id = try std.fmt.parseInt(i64, user.value(0, 0), 10);
    var id: [20]u8 = undefined;
    const user_id_parameter = try std.fmt.bufPrint(&id, "{d}", .{user_id});
    var application = try pool.query("INSERT INTO applications (user_id,minecraft_nickname,minecraft_nickname_normalized,client_type,about_me,discovery_source,status,decision_reason) VALUES ($1::bigint,$2,$3,$4::minecraft_client_type,'test','test',$5::application_status,CASE WHEN $5 IN ('rejected_retryable','rejected_final','banned') THEN 'test decision' ELSE NULL END)", &.{ user_id_parameter, nickname, canonical, client_type, status });
    application.deinit();
    return user_id;
}

fn version(repo: *repository.Repository) !u64 {
    return repo.whitelistVersion();
}

test "real route cursor PostgreSQL bigint boundaries" {
    var database = try testDatabase();
    defer database.deinit();
    var configuration: config.Config = undefined;
    configuration.game_auth_credentials = @constCast(&[_]config.GameAuthCredential{.{ .server_id = @constCast("test"), .secret = @constCast("SYNTHETIC_SECRET") }});
    var router = routes.Router.init(std.testing.allocator, &database.pool, &configuration);
    defer router.deinit();
    var server = http.Server.init(std.testing.allocator);
    defer server.deinit();
    try routes.register(&server, &router);
    var statuses: [3]u16 = undefined;
    for ([_][]const u8{ "9223372036854775807", "9223372036854775808", "18446744073709551615" }, 0..) |decimal, index| {
        const target = try std.mem.concat(std.testing.allocator, u8, &.{ "/internal/game-auth/v1/whitelist?cursor=", decimal });
        defer std.testing.allocator.free(target);
        var result = try server.dispatch(.{ .method = .GET, .target = target, .authorization = "Bearer SYNTHETIC_SECRET" });
        defer result.deinit();
        std.debug.print("CURSOR reproduction decimal={s} HTTP={d}\n", .{ decimal, result.status });
        statuses[index] = result.status;
        if (index != 0) try std.testing.expectEqualStrings("{\"outcome\":\"deny\"}", result.body);
    }
    try std.testing.expectEqualSlices(u16, &.{ 200, 400, 400 }, &statuses);
}

const IdentityMutationRace = struct {
    pool: *db.Pool,
    sql: []const u8,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failure: ?anyerror = null,
    fn run(self: *@This()) void {
        execute(self.pool, self.sql) catch |err| {
            self.failure = err;
        };
        self.done.store(true, .release);
    }
};

const PasswordMutationRace = struct {
    pool: *db.Pool,
    user_id: i64,
    failure: ?anyerror = null,
    fn run(self: *@This()) void {
        var applications = @import("applications").ApplicationRepository.init(self.pool);
        applications.replacePassword(self.user_id, "synthetic-replacement") catch |err| {
            self.failure = err;
        };
    }
};

test "password replacement obtains user before application and credential tuples" {
    var database = try testDatabase();
    defer database.deinit();
    const user_id = try insertApplication(&database.pool, "Alex", "alex", "cracked", "approved");
    try execute(&database.pool, "INSERT INTO password_credentials(user_id,password_hash) SELECT user_id,'synthetic-old' FROM applications");
    var other = try db.Pool.open(std.testing.allocator, database.database_url);
    defer other.close();
    var pid = try other.query("SELECT pg_backend_pid()", &.{});
    defer pid.deinit();
    try execute(&database.pool, "BEGIN; SELECT id FROM users FOR UPDATE");
    var ended = false;
    defer if (!ended) execute(&database.pool, "ROLLBACK") catch {};
    var race = PasswordMutationRace{ .pool = &other, .user_id = user_id };
    const worker = try std.Thread.spawn(.{}, PasswordMutationRace.run, .{&race});
    {
        defer worker.join();
        errdefer {
            execute(&database.pool, "ROLLBACK") catch {};
            ended = true;
        }
        try waitForLock(&database.pool, pid.value(0, 0), null);
        try execute(&database.pool, "SELECT user_id FROM applications FOR UPDATE NOWAIT; SELECT user_id FROM password_credentials FOR UPDATE NOWAIT");
        try execute(&database.pool, "COMMIT");
        ended = true;
    }
    if (race.failure) |err| return err;
    try scalar(&database.pool, "SELECT password_hash FROM password_credentials", "synthetic-replacement");
    try idleAndUnlocked(&database.pool, &other);
}

test "real premium repository survives concurrent supported binding before identity DML" {
    var database = try testDatabase();
    defer database.deinit();
    _ = try insertApplication(&database.pool, "Alex", "alex", "licensed", "approved");
    // Pause only at the call boundary, AFTER the real repository owns the user
    // and BEFORE the original production helper issues identity DML.
    try execute(&database.pool, "ALTER FUNCTION game_auth_bind_premium(bigint,uuid) RENAME TO evidence_original_bind; CREATE FUNCTION game_auth_bind_premium(owner_id bigint, asserted_uuid uuid) RETURNS boolean LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_advisory_xact_lock(67123620); RETURN evidence_original_bind(owner_id,asserted_uuid); END $$; SELECT pg_advisory_lock(67123620)");
    var premium = try db.Pool.open(std.testing.allocator, database.database_url);
    defer premium.close();
    var mutation = try db.Pool.open(std.testing.allocator, database.database_url);
    defer mutation.close();
    try execute(&premium, "SET deadlock_timeout='50ms'; SET statement_timeout='8s'");
    try execute(&mutation, "SET deadlock_timeout='5s'; SET statement_timeout='8s'");
    var premium_pid = try premium.query("SELECT pg_backend_pid()", &.{});
    defer premium_pid.deinit();
    var mutation_pid = try mutation.query("SELECT pg_backend_pid()", &.{});
    defer mutation_pid.deinit();
    var authentication = PremiumRace{ .pool = &premium, .nickname = "alex" };
    var change = IdentityMutationRace{ .pool = &mutation, .sql = "SELECT evidence_original_bind(user_id,'8667ba71-b85a-4004-af54-457a9734eed7') FROM applications" };
    const auth_worker = try std.Thread.spawn(.{}, PremiumRace.run, .{&authentication});
    {
        defer auth_worker.join();
        errdefer execute(&database.pool, "SELECT pg_advisory_unlock(67123620)") catch {};
        try waitForLock(&database.pool, premium_pid.value(0, 0), "advisory");
        const change_worker = try std.Thread.spawn(.{}, IdentityMutationRace.run, .{&change});
        {
            defer change_worker.join();
            defer execute(&database.pool, "SELECT pg_advisory_unlock(67123620)") catch {};
            try waitForLock(&database.pool, mutation_pid.value(0, 0), null);
        }
    }
    if (authentication.failure) |err| return err;
    if (change.failure) |err| return err;
    try std.testing.expect(authentication.allowed);
    try idleAndUnlocked(&database.pool, &premium);
    try idleAndUnlocked(&database.pool, &mutation);
}

// Two mutation participants; the user-lock owner also observes the other PID.
// The real bind function must wait on the user BEFORE locking an identity tuple.
test "premium binding entry point orders user before identity under contention" {
    var database = try testDatabase();
    defer database.deinit();
    _ = try insertApplication(&database.pool, "Alex", "alex", "licensed", "approved");
    var other = try db.Pool.open(std.testing.allocator, database.database_url);
    defer other.close();
    var pid = try other.query("SELECT pg_backend_pid()", &.{});
    defer pid.deinit();
    try execute(&other, "SET deadlock_timeout='5s'; SET statement_timeout='8s'");
    try execute(&database.pool, "SET deadlock_timeout='50ms'; SET statement_timeout='8s'; BEGIN; SELECT id FROM users FOR UPDATE");
    var ended = false;
    defer if (!ended) execute(&database.pool, "ROLLBACK") catch {};
    var race = IdentityMutationRace{ .pool = &other, .sql = "SELECT game_auth_bind_premium(user_id,'8667ba71-b85a-4004-af54-457a9734eed7') FROM applications" };
    const worker = try std.Thread.spawn(.{}, IdentityMutationRace.run, .{&race});
    {
        defer worker.join();
        errdefer {
            execute(&database.pool, "ROLLBACK") catch {};
            ended = true;
        }
        try waitForLock(&database.pool, pid.value(0, 0), null);
        // Baseline: other holds identity -> waits user; this holds user -> waits
        // identity, and its shorter deadlock_timeout deterministically aborts it.
        try scalar(&database.pool, "SELECT game_auth_bind_premium(user_id,'8667ba71-b85a-4004-af54-457a9734eed7') FROM applications", "t");
        try execute(&database.pool, "COMMIT");
        ended = true;
    }
    if (race.failure) |err| return err;
    var repo = repository.Repository.init(&database.pool);
    var identity = try licensed(&repo);
    defer identity.deinit(std.testing.allocator);
    try idleAndUnlocked(&database.pool, &other);
}

test "unsafe direct identity UPDATE cannot wait for user while holding identity tuple" {
    try unsafeIdentityDml("UPDATE game_identities SET licensed_mojang_uuid=NULL");
}

test "unsafe direct identity DELETE cannot wait for user while holding identity tuple" {
    try unsafeIdentityDml("DELETE FROM game_identities");
}

fn unsafeIdentityDml(sql: []const u8) !void {
    var database = try testDatabase();
    defer database.deinit();
    _ = try insertApplication(&database.pool, "Alex", "alex", "licensed", "approved");
    var other = try db.Pool.open(std.testing.allocator, database.database_url);
    defer other.close();
    var pid = try other.query("SELECT pg_backend_pid()", &.{});
    defer pid.deinit();
    try execute(&other, "SET deadlock_timeout='5s'; SET statement_timeout='8s'");
    try execute(&database.pool, "SET deadlock_timeout='50ms'; SET statement_timeout='8s'; BEGIN; SELECT id FROM users FOR UPDATE");
    var ended = false;
    defer if (!ended) execute(&database.pool, "ROLLBACK") catch {};
    var race = IdentityMutationRace{ .pool = &other, .sql = sql };
    const worker = try std.Thread.spawn(.{}, IdentityMutationRace.run, .{&race});
    {
        defer worker.join();
        errdefer {
            execute(&database.pool, "ROLLBACK") catch {};
            ended = true;
        }
        const start = std.time.milliTimestamp();
        while (!race.done.load(.acquire) and std.time.milliTimestamp() - start < 3000) {
            try execute(&database.pool, "SELECT pg_stat_clear_snapshot()");
            var state = try database.pool.query("SELECT wait_event_type='Lock' FROM pg_stat_activity WHERE pid=$1::integer", &.{pid.value(0, 0)});
            const waiting = std.mem.eql(u8, state.value(0, 0), "t");
            state.deinit();
            if (waiting) break;
            std.time.sleep(5 * std.time.ns_per_ms);
        }
        try scalar(&database.pool, "SELECT game_auth_bind_premium(user_id,'8667ba71-b85a-4004-af54-457a9734eed7') FROM applications", "t");
        try execute(&database.pool, "COMMIT");
        ended = true;
    }
    try std.testing.expectEqual(@as(?anyerror, error.QueryFailed), race.failure);
    try scalar(&database.pool, "SELECT count(*) FROM game_identities", "1");
    try idleAndUnlocked(&database.pool, &other);
}

test "supported UUID unbind serializes before tuples and invalidates leases" {
    try supportedIdentityMutation(false);
}

test "supported identity deletion serializes before tuples and invalidates leases" {
    try supportedIdentityMutation(true);
}

fn supportedIdentityMutation(remove: bool) !void {
    var database = try testDatabase();
    defer database.deinit();
    _ = try insertApplication(&database.pool, "Alex", "alex", "licensed", "approved");
    var repo = repository.Repository.init(&database.pool);
    var identity = try licensed(&repo);
    defer identity.deinit(std.testing.allocator);
    const lease = (try repo.issueLease("server-a", identity)) orelse return error.ExpectedLease;
    const before = try repo.whitelistVersion();
    var other = try db.Pool.open(std.testing.allocator, database.database_url);
    defer other.close();
    var pid = try other.query("SELECT pg_backend_pid()", &.{});
    defer pid.deinit();
    try execute(&database.pool, "BEGIN; SELECT id FROM users FOR UPDATE");
    var ended = false;
    defer if (!ended) execute(&database.pool, "ROLLBACK") catch {};
    var race = IdentityMutationRace{ .pool = &other, .sql = if (remove) "SELECT game_auth_delete_identity(user_id) FROM applications" else "SELECT game_auth_set_identity_uuid(user_id,NULL) FROM applications" };
    const worker = try std.Thread.spawn(.{}, IdentityMutationRace.run, .{&race});
    {
        defer worker.join();
        errdefer {
            execute(&database.pool, "ROLLBACK") catch {};
            ended = true;
        }
        try waitForMutationLock(&database.pool, pid.value(0, 0), &race);
        try execute(&database.pool, "SELECT identity_id FROM game_identities FOR UPDATE NOWAIT");
        try execute(&database.pool, "COMMIT");
        ended = true;
    }
    if (race.failure) |err| return err;
    try std.testing.expect((try repo.whitelistVersion()) > before);
    try std.testing.expect((try repo.issueLease("server-a", identity)) == null);
    try std.testing.expect((try repo.checkLease("server-a", &lease.token)) == .disconnect);
    if (remove) {
        try scalar(&database.pool, "SELECT count(*) FROM game_auth_leases", "0");
        try scalar(&database.pool, "SELECT count(*) FROM game_identities", "0");
    } else try scalar(&database.pool, "SELECT licensed_mojang_uuid IS NULL FROM game_identities", "t");
    try idleAndUnlocked(&database.pool, &other);
}

fn waitForMutationLock(observer: *db.Pool, pid: []const u8, race: *IdentityMutationRace) !void {
    const start = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - start < 3000) {
        if (race.done.load(.acquire)) return race.failure orelse error.ExpectedConcurrentLockWait;
        try execute(observer, "SELECT pg_stat_clear_snapshot()");
        var rows = try observer.query("SELECT wait_event_type='Lock' FROM pg_stat_activity WHERE pid=$1::integer", &.{pid});
        const waiting = rows.rowCount() == 1 and std.mem.eql(u8, rows.value(0, 0), "t");
        rows.deinit();
        if (waiting) return;
        std.time.sleep(5 * std.time.ns_per_ms);
    }
    return error.ExpectedConcurrentLockWait;
}

test "approved cracked identity appears once with canonical offline UUID" {
    var database = try testDatabase();
    defer database.deinit();
    _ = try insertApplication(&database.pool, "Steve", "steve", "cracked", "approved");
    var repo = repository.Repository.init(&database.pool);
    var snapshot = try repo.whitelistSnapshot(null);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), snapshot.identities.len);
    try std.testing.expectEqualStrings("steve", snapshot.identities[0].canonical_nickname);
    try std.testing.expectEqualStrings("5627dd98-e6be-3c21-b8a8-e92344183641", snapshot.identities[0].uuid);
}

test "approved licensed identity without verified Mojang UUID is not emitted as playable" {
    var database = try testDatabase();
    defer database.deinit();
    _ = try insertApplication(&database.pool, "Alex", "alex", "licensed", "approved");
    var repo = repository.Repository.init(&database.pool);
    var snapshot = try repo.whitelistSnapshot(null);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), snapshot.identities.len);
}

test "approved licensed identity with verified Mojang UUID appears once" {
    var database = try testDatabase();
    defer database.deinit();
    _ = try insertApplication(&database.pool, "Alex", "alex", "licensed", "approved");
    var repo = repository.Repository.init(&database.pool);
    var decision = try repo.verifyPremium("alex", "8667ba71-b85a-4004-af54-457a9734eed7");
    switch (decision) {
        .allow => |*identity| identity.deinit(std.testing.allocator),
        .deny => return error.ExpectedPremiumIdentity,
    }
    var snapshot = try repo.whitelistSnapshot(null);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), snapshot.identities.len);
    try std.testing.expectEqualStrings("8667ba71-b85a-4004-af54-457a9734eed7", snapshot.identities[0].uuid);
}

test "pending rejected and banned identities are absent" {
    const statuses = [_][]const u8{ "pending", "rejected_retryable", "rejected_final", "banned" };
    for (statuses) |status| {
        var database = try testDatabase();
        defer database.deinit();
        _ = try insertApplication(&database.pool, "Steve", "steve", "cracked", status);
        var repo = repository.Repository.init(&database.pool);
        var snapshot = try repo.whitelistSnapshot(null);
        defer snapshot.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), snapshot.identities.len);
    }
}

test "canonical nickname collisions cannot create two identities" {
    var database = try testDatabase();
    defer database.deinit();
    _ = try insertApplication(&database.pool, "Steve", "steve", "cracked", "approved");
    var second_user = try database.pool.query("INSERT INTO users (discord_id,discord_username) VALUES ('100000000000000002','second') RETURNING id", &.{});
    defer second_user.deinit();
    const duplicate = database.pool.query("INSERT INTO applications (user_id,minecraft_nickname,minecraft_nickname_normalized,client_type,about_me,discovery_source,status) VALUES ($1::bigint,'sTeVe','steve','cracked','test','test','approved')", &.{second_user.value(0, 0)});
    try std.testing.expectError(error.QueryFailed, duplicate);
}

test "cursor version changes after nickname client type status and premium UUID changes" {
    var database = try testDatabase();
    defer database.deinit();
    const user_id = try insertApplication(&database.pool, "Steve", "steve", "cracked", "approved");
    var repo = repository.Repository.init(&database.pool);
    var id: [20]u8 = undefined;
    const user_id_parameter = try std.fmt.bufPrint(&id, "{d}", .{user_id});
    var previous = try version(&repo);
    for ([_][]const u8{
        "UPDATE applications SET minecraft_nickname='SteveTwo',minecraft_nickname_normalized='stevetwo' WHERE user_id=$1::bigint",
        "UPDATE applications SET client_type='licensed' WHERE user_id=$1::bigint",
        "UPDATE applications SET status='pending' WHERE user_id=$1::bigint",
    }) |statement| {
        var changed = try database.pool.query(statement, &.{user_id_parameter});
        changed.deinit();
        const current = try version(&repo);
        try std.testing.expect(current > previous);
        previous = current;
    }
    var approved = try database.pool.query("UPDATE applications SET status='approved' WHERE user_id=$1::bigint", &.{user_id_parameter});
    approved.deinit();
    previous = try version(&repo);
    var premium = try repo.verifyPremium("stevetwo", "8667ba71-b85a-4004-af54-457a9734eed7");
    switch (premium) {
        .allow => |*identity| identity.deinit(std.testing.allocator),
        .deny => return error.ExpectedPremiumIdentity,
    }
    try std.testing.expect((try version(&repo)) > previous);
}

test "password credential hash is never selected into whitelist result rows" {
    var database = try testDatabase();
    defer database.deinit();
    const user_id = try insertApplication(&database.pool, "Steve", "steve", "cracked", "approved");
    var id: [20]u8 = undefined;
    const user_id_parameter = try std.fmt.bufPrint(&id, "{d}", .{user_id});
    var credential = try database.pool.query("INSERT INTO password_credentials (user_id,password_hash) VALUES ($1::bigint,'not-a-route-value')", &.{user_id_parameter});
    credential.deinit();
    var repo = repository.Repository.init(&database.pool);
    var snapshot = try repo.whitelistSnapshot(null);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), snapshot.identities.len);
    try std.testing.expect(std.mem.indexOf(u8, snapshot.identities[0].nickname, "not-a-route-value") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot.identities[0].uuid, "not-a-route-value") == null);
}

// Explicit opt-in only: never run by test-game-auth or the compile-only check.
test "lease binds identity generation server expiry and stores only token hash" {
    var database = try testDatabase();
    defer database.deinit();
    _ = try insertApplication(&database.pool, "Alex", "alex", "licensed", "approved");
    var repo = repository.Repository.init(&database.pool);
    try std.testing.expectEqual(repository.Policy.licensed, try repo.nicknamePolicy("alex"));
    var unbound = try repo.whitelistSnapshot(null);
    defer unbound.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), unbound.identities.len);
    var decision = try repo.verifyPremium("alex", "8667ba71-b85a-4004-af54-457a9734eed7");
    if (decision != .allow) return error.ExpectedPremiumIdentity;
    defer decision.allow.deinit(std.testing.allocator);
    const lease = (try repo.issueLease("server-a", decision.allow)) orelse return error.ExpectedLease;
    const cross_server = try repo.checkLease("server-b", &lease.token);
    try std.testing.expect(cross_server == .disconnect);
    var valid = try repo.checkLease("server-a", &lease.token);
    if (valid != .continue_session) return error.ExpectedContinuation;
    valid.continue_session.identity.deinit(std.testing.allocator);
    var stored = try database.pool.query("SELECT octet_length(lease_hash),encode(lease_hash,'hex'),identity_id,authentication_generation FROM game_auth_leases", &.{});
    defer stored.deinit();
    try std.testing.expectEqualStrings("32", stored.value(0, 0));
    try std.testing.expect(!std.mem.eql(u8, &lease.token, stored.value(0, 1)));
    var banned = try database.pool.query("UPDATE applications SET status='banned',decision_reason='test' WHERE minecraft_nickname_normalized='alex'", &.{});
    banned.deinit();
    var approved = try database.pool.query("UPDATE applications SET status='approved',decision_reason=NULL WHERE minecraft_nickname_normalized='alex'", &.{});
    approved.deinit();
    try std.testing.expect((try repo.checkLease("server-a", &lease.token)) == .disconnect);
    // The authenticated snapshot itself may no longer issue a lease.
    try std.testing.expect((try repo.issueLease("server-a", decision.allow)) == null);
    var fresh = try repo.verifyPremium("alex", "8667ba71-b85a-4004-af54-457a9734eed7");
    if (fresh != .allow) return error.ExpectedPremiumIdentity;
    defer fresh.allow.deinit(std.testing.allocator);
    const expiring = (try repo.issueLease("server-a", fresh.allow)) orelse return error.ExpectedLease;
    var expire = try database.pool.query("UPDATE game_auth_leases SET expires_at=clock_timestamp()-INTERVAL '1 second'", &.{});
    expire.deinit();
    try std.testing.expect((try repo.checkLease("server-a", &expiring.token)) == .disconnect);
    const before_delete = try repo.whitelistVersion();
    var removed = try database.pool.query("DELETE FROM game_identities", &.{});
    removed.deinit();
    try std.testing.expect((try repo.whitelistVersion()) > before_delete);
    var recreated = try database.pool.query("INSERT INTO game_identities(user_id,licensed_mojang_uuid) SELECT user_id,'8667ba71-b85a-4004-af54-457a9734eed7'::uuid FROM applications RETURNING identity_id", &.{});
    defer recreated.deinit();
    try std.testing.expect((try std.fmt.parseInt(i64, recreated.value(0, 0), 10)) != fresh.allow.identity_id);
    try std.testing.expect((try repo.checkLease("server-a", &expiring.token)) == .disconnect);
    var remaining = try database.pool.query("SELECT count(*) FROM game_auth_leases", &.{});
    defer remaining.deinit();
    try std.testing.expectEqualStrings("0", remaining.value(0, 0));
}

fn execute(pool: *db.Pool, sql: []const u8) !void {
    var rows = try pool.query(sql, &.{});
    rows.deinit();
}

fn scalar(pool: *db.Pool, sql: []const u8, expected: []const u8) !void {
    var rows = try pool.query(sql, &.{});
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rowCount());
    try std.testing.expectEqualStrings(expected, rows.value(0, 0));
}

fn licensed(repo: *repository.Repository) !repository.Identity {
    const decision = try repo.verifyPremium("alex", "8667ba71-b85a-4004-af54-457a9734eed7");
    if (decision != .allow) return error.ExpectedPremiumIdentity;
    return decision.allow;
}

// Catches SQL parameter type inference breaking real INSERT/refresh, something
// compiling embedded SQL or replacing the repository cannot detect.
test "real lease insertion accepts UUID text and renews for five minutes" {
    var database = try testDatabase();
    defer database.deinit();
    _ = try insertApplication(&database.pool, "Alex", "alex", "licensed", "approved");
    var repo = repository.Repository.init(&database.pool);
    var identity = try licensed(&repo);
    defer identity.deinit(std.testing.allocator);
    const lease = (try repo.issueLease("server-a", identity)) orelse return error.ExpectedLease;
    try std.testing.expect(@abs(lease.expires_at - std.time.timestamp() - 300) <= 2);
    try execute(&database.pool, "UPDATE game_auth_leases SET expires_at=clock_timestamp()+INTERVAL '30 seconds'");
    var continued = try repo.checkLease("server-a", &lease.token);
    if (continued != .continue_session) return error.ExpectedContinuation;
    defer continued.continue_session.identity.deinit(std.testing.allocator);
    try std.testing.expect(@abs(continued.continue_session.lease.expires_at - std.time.timestamp() - 300) <= 2);
    try std.testing.expectEqualStrings(&lease.token, &continued.continue_session.lease.token);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&lease.token, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    var stored = try database.pool.query("SELECT encode(lease_hash,'hex') FROM game_auth_leases", &.{});
    defer stored.deinit();
    try std.testing.expectEqualStrings(&hex, stored.value(0, 0));
}

// Each SQL mutation is deliberately real DML through the production migration
// triggers. Removing any generation trigger must allow a stale issue/renewal
// and fail this test. No duplicate authorization implementation is used.
test "every credential nickname client status and UUID transition invalidates old authorization" {
    const mutations = [_][]const u8{
        "INSERT INTO password_credentials(user_id,password_hash) SELECT user_id,'synthetic-insert' FROM applications",
        "UPDATE password_credentials SET password_hash='synthetic-replacement'",
        "UPDATE password_credentials SET password_hash=password_hash,changed_at=clock_timestamp()",
        "DELETE FROM password_credentials",
        "UPDATE applications SET minecraft_nickname='ALEX'",
        "UPDATE applications SET minecraft_nickname='AlexTwo',minecraft_nickname_normalized='alextwo'",
        "UPDATE applications SET client_type='cracked'",
        "UPDATE applications SET status='pending'",
        "UPDATE applications SET status='rejected_retryable',decision_reason='synthetic'",
        "UPDATE applications SET status='rejected_final',decision_reason='synthetic'",
        "UPDATE applications SET status='banned',decision_reason='synthetic'",
        "UPDATE game_identities SET licensed_mojang_uuid='11111111-1111-4111-8111-111111111111'",
        "UPDATE game_identities SET licensed_mojang_uuid=NULL",
    };
    for (mutations, 0..) |mutation, index| {
        std.debug.print("TRANSITION {d}: {s}\n", .{ index, mutation });
        var database = try testDatabase();
        defer database.deinit();
        _ = try insertApplication(&database.pool, "Alex", "alex", "licensed", "approved");
        if (index >= 1 and index <= 3) try execute(&database.pool, "INSERT INTO password_credentials(user_id,password_hash) SELECT user_id,'synthetic-old' FROM applications");
        var repo = repository.Repository.init(&database.pool);
        var identity = try licensed(&repo);
        defer identity.deinit(std.testing.allocator);
        const lease = (try repo.issueLease("server-a", identity)) orelse return error.ExpectedLease;
        try execute(&database.pool, mutation);
        var generation = try database.pool.query("SELECT authentication_generation FROM game_identities", &.{});
        defer generation.deinit();
        try std.testing.expect((try std.fmt.parseInt(u64, generation.value(0, 0), 10)) > identity.authentication_generation);
        try std.testing.expect((try repo.checkLease("server-a", &lease.token)) == .disconnect);
        try std.testing.expect((try repo.issueLease("server-a", identity)) == null);
        // Restoring access never restores the old generation.
        try execute(&database.pool, "UPDATE applications SET status='approved',decision_reason=NULL");
        try std.testing.expect((try repo.checkLease("server-a", &lease.token)) == .disconnect);
    }
}

test "real cracked service uses existing verifier and password replacement revokes lease" {
    var database = try testDatabase();
    defer database.deinit();
    const user_id = try insertApplication(&database.pool, "Player", "player", "cracked", "approved");
    const hash = try domain.password.hashPassword(std.testing.allocator, "SYNTHETIC_PASSWORD_SENTINEL");
    defer std.testing.allocator.free(hash);
    var credential = try database.pool.query("INSERT INTO password_credentials(user_id,password_hash) SELECT user_id,$1 FROM applications", &.{hash});
    credential.deinit();
    var auth = service.GameAuthService.init(std.testing.allocator, &database.pool);
    defer auth.deinit();
    const denied = try auth.crackedLogin("server-a", "{\"nickname\":\"Player\",\"password\":\"WRONG_PASSWORD_SENTINEL\"}");
    defer std.testing.allocator.free(denied);
    try std.testing.expect(std.mem.indexOf(u8, denied, "\"outcome\":\"deny\"") != null);
    const allowed = try auth.crackedLogin("server-a", "{\"nickname\":\"PLAYER\",\"password\":\"SYNTHETIC_PASSWORD_SENTINEL\"}");
    defer std.testing.allocator.free(allowed);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, allowed, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("allow", parsed.value.object.get("outcome").?.string);
    try std.testing.expectEqualStrings("a01e3843-e521-3998-958a-f459800e4d11", parsed.value.object.get("uuid").?.string);
    const token = parsed.value.object.get("lease").?.string;
    const replacement = try domain.password.hashPassword(std.testing.allocator, "SYNTHETIC_REPLACEMENT_PASSWORD");
    defer std.testing.allocator.free(replacement);
    var applications = @import("applications").ApplicationRepository.init(&database.pool);
    try applications.replacePassword(user_id, replacement);
    try std.testing.expect((try auth.repository.checkLease("server-a", token)) == .disconnect);
    try std.testing.expect((try auth.repository.authenticateCracked("player", "SYNTHETIC_PASSWORD_SENTINEL")) == .deny);
    var fresh = try auth.repository.authenticateCracked("player", "SYNTHETIC_REPLACEMENT_PASSWORD");
    if (fresh != .allow) return error.ExpectedCrackedIdentity;
    defer fresh.allow.deinit(std.testing.allocator);
    const cracked_lease = (try auth.repository.issueLease("server-a", fresh.allow)) orelse return error.ExpectedLease;
    try execute(&database.pool, "UPDATE applications SET client_type='licensed'");
    var premium = try auth.repository.verifyPremium("player", "8667ba71-b85a-4004-af54-457a9734eed7");
    if (premium != .allow) return error.ExpectedPremiumIdentity;
    defer premium.allow.deinit(std.testing.allocator);
    try std.testing.expect(premium.allow.authentication_generation > fresh.allow.authentication_generation);
    try std.testing.expect((try auth.repository.checkLease("server-a", &cracked_lease.token)) == .disconnect);
    try std.testing.expect((try auth.repository.issueLease("server-a", fresh.allow)) == null);
    try std.testing.expect((try auth.repository.issueLease("server-a", premium.allow)) != null);
    var audits = try database.pool.query("SELECT server_id,outcome,reason_category FROM game_auth_audit ORDER BY id", &.{});
    defer audits.deinit();
    try std.testing.expectEqual(@as(usize, 2), audits.rowCount());
    for (0..audits.rowCount()) |i| {
        for (0..3) |j| {
            const value = audits.value(i, j);
            for ([_][]const u8{ "PASSWORD_SENTINEL", hash, token, "{\"nickname\"" }) |sentinel| try std.testing.expect(std.mem.indexOf(u8, value, sentinel) == null);
        }
        try std.testing.expectEqualStrings("cracked_login", audits.value(i, 2));
    }
    for ([_][]const u8{ "PASSWORD_SENTINEL", hash, token }) |sentinel| try std.testing.expect(std.mem.indexOf(u8, denied, sentinel) == null);
    try std.testing.expect(std.mem.indexOf(u8, allowed, hash) == null);
    try std.testing.expect(std.mem.indexOf(u8, allowed, "PASSWORD_SENTINEL") == null);
}

test "real policy and unchanged differ from authoritative empty snapshot" {
    var database = try testDatabase();
    defer database.deinit();
    var auth = service.GameAuthService.init(std.testing.allocator, &database.pool);
    defer auth.deinit();
    const empty = try auth.whitelist(null);
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqualStrings("{\"outcome\":\"snapshot\",\"whitelist_version\":0,\"identities\":[]}", empty);
    const unchanged = try auth.whitelist(0);
    defer std.testing.allocator.free(unchanged);
    try std.testing.expectEqualStrings("{\"outcome\":\"unchanged\",\"whitelist_version\":0}", unchanged);
    try std.testing.expectEqual(repository.Policy.denied, try auth.repository.nicknamePolicy("missing"));
    _ = try insertApplication(&database.pool, "Alex", "alex", "licensed", "approved");
    const policy = try auth.nicknamePolicy("ALEX");
    defer std.testing.allocator.free(policy);
    try std.testing.expectEqualStrings("{\"outcome\":\"licensed\"}", policy);
    var snapshot = try auth.repository.whitelistSnapshot(0);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expect(!snapshot.unchanged);
    try std.testing.expect(snapshot.version > 0);
    try std.testing.expectEqual(@as(usize, 0), snapshot.identities.len);
}

test "identity application and user deletions cascade leases advance cursor and recreate new identity" {
    for ([_][]const u8{ "DELETE FROM game_identities", "DELETE FROM applications", "DELETE FROM users" }, 0..) |deletion, index| {
        var database = try testDatabase();
        defer database.deinit();
        _ = try insertApplication(&database.pool, "Alex", "alex", "licensed", "approved");
        var repo = repository.Repository.init(&database.pool);
        var identity = try licensed(&repo);
        defer identity.deinit(std.testing.allocator);
        const lease = (try repo.issueLease("server-a", identity)) orelse return error.ExpectedLease;
        const before = try repo.whitelistVersion();
        try execute(&database.pool, deletion);
        try std.testing.expect((try repo.whitelistVersion()) > before);
        try scalar(&database.pool, "SELECT count(*) FROM game_auth_leases", "0");
        var removed = try repo.whitelistSnapshot(before);
        defer removed.deinit(std.testing.allocator);
        try std.testing.expect(!removed.unchanged);
        try std.testing.expect(removed.version > before);
        try std.testing.expectEqual(@as(usize, 0), removed.identities.len);
        if (index == 0) {
            try execute(&database.pool, "INSERT INTO game_identities(user_id) SELECT user_id FROM applications");
        } else if (index == 1) {
            try execute(&database.pool, "INSERT INTO applications(user_id,minecraft_nickname,minecraft_nickname_normalized,client_type,about_me,discovery_source,status) SELECT id,'Alex','alex','licensed','test','test','approved' FROM users");
        } else _ = try insertApplication(&database.pool, "Alex", "alex", "licensed", "approved");
        var recreated = try licensed(&repo);
        defer recreated.deinit(std.testing.allocator);
        try std.testing.expect(recreated.identity_id != identity.identity_id);
        try std.testing.expect((try repo.checkLease("server-a", &lease.token)) == .disconnect);
        try std.testing.expect((try repo.issueLease("server-a", identity)) == null);
    }
}

test "bounded retention removes oldest thousand expired leases and seven day audits only" {
    var database = try testDatabase();
    defer database.deinit();
    _ = try insertApplication(&database.pool, "Alex", "alex", "licensed", "approved");
    var repo = repository.Repository.init(&database.pool);
    try execute(&database.pool, "INSERT INTO game_auth_leases(lease_hash,identity_id,server_id,client_type,authentication_generation,uuid,expires_at) SELECT decode(lpad(to_hex(n),64,'0'),'hex'),identity_id,'synthetic','licensed',authentication_generation,'8667ba71-b85a-4004-af54-457a9734eed7',clock_timestamp()-INTERVAL '2 days'+n*INTERVAL '1 second' FROM game_identities CROSS JOIN generate_series(1,1005) n");
    try execute(&database.pool, "INSERT INTO game_auth_leases(lease_hash,identity_id,server_id,client_type,authentication_generation,uuid,expires_at) SELECT decode(repeat('ff',32),'hex'),identity_id,'synthetic','licensed',authentication_generation,'8667ba71-b85a-4004-af54-457a9734eed7',clock_timestamp()+INTERVAL '1 day' FROM game_identities");
    try execute(&database.pool, "INSERT INTO game_auth_audit(server_id,outcome,reason_category,created_at) SELECT 'synthetic','deny','fixed',clock_timestamp()-INTERVAL '8 days'+n*INTERVAL '1 second' FROM generate_series(1,1005) n; INSERT INTO game_auth_audit(server_id,outcome,reason_category) VALUES ('synthetic','deny','recent')");
    try repo.cleanupExpired();
    try scalar(&database.pool, "SELECT count(*) FROM game_auth_leases", "6");
    try scalar(&database.pool, "SELECT count(*) FROM game_auth_leases WHERE expires_at>clock_timestamp()", "1");
    try scalar(&database.pool, "SELECT min(encode(lease_hash,'hex'))=lpad(to_hex(1001),64,'0') FROM game_auth_leases", "t");
    try scalar(&database.pool, "SELECT count(*) FROM game_auth_audit", "6");
    try scalar(&database.pool, "SELECT min(id) FROM game_auth_audit", "1001");
    try scalar(&database.pool, "SELECT count(*) FROM game_auth_audit WHERE reason_category='recent'", "1");
    try repo.cleanupExpired();
    try scalar(&database.pool, "SELECT count(*) FROM game_auth_leases", "1");
    try scalar(&database.pool, "SELECT count(*) FROM game_auth_audit", "1");
}

fn idleAndUnlocked(observer: *db.Pool, subject: *db.Pool) !void {
    var pid = try subject.query("SELECT pg_backend_pid()", &.{});
    defer pid.deinit();
    var state = try observer.query("SELECT state,xact_start IS NULL FROM pg_stat_activity WHERE pid=$1::integer", &.{pid.value(0, 0)});
    defer state.deinit();
    try std.testing.expectEqualStrings("idle", state.value(0, 0));
    try std.testing.expectEqualStrings("t", state.value(0, 1));
    // A connection being reusable alone does not prove its transaction ended.
    // Independently acquire row locks from another connection without waiting.
    try execute(observer, "BEGIN; SELECT id FROM users FOR UPDATE NOWAIT; SELECT identity_id FROM game_identities FOR UPDATE NOWAIT; ROLLBACK");
}

test "premium allow commits and every ordinary denial and query error releases transaction locks" {
    var database = try testDatabase();
    defer database.deinit();
    var observer = try db.Pool.open(std.testing.allocator, database.database_url);
    defer observer.close();
    var repo = repository.Repository.init(&database.pool);
    try std.testing.expect((try repo.verifyPremium("missing", "INVALID_UUID_SENTINEL")) == .deny);
    try idleAndUnlocked(&observer, &database.pool);
    try std.testing.expect((try repo.verifyPremium("missing", "8667ba71-b85a-4004-af54-457a9734eed7")) == .deny);
    try idleAndUnlocked(&observer, &database.pool);
    _ = try insertApplication(&database.pool, "Alex", "alex", "licensed", "pending");
    try std.testing.expect((try repo.verifyPremium("alex", "8667ba71-b85a-4004-af54-457a9734eed7")) == .deny);
    try idleAndUnlocked(&observer, &database.pool);
    try execute(&database.pool, "UPDATE applications SET status='approved'");
    try execute(&database.pool, "UPDATE applications SET client_type='cracked'");
    try std.testing.expect((try repo.verifyPremium("alex", "8667ba71-b85a-4004-af54-457a9734eed7")) == .deny);
    try idleAndUnlocked(&observer, &database.pool);
    try execute(&database.pool, "UPDATE applications SET client_type='licensed'");
    var identity = try licensed(&repo);
    defer identity.deinit(std.testing.allocator);
    try idleAndUnlocked(&observer, &database.pool);
    try scalar(&observer, "SELECT licensed_mojang_uuid::text FROM game_identities", "8667ba71-b85a-4004-af54-457a9734eed7");
    try std.testing.expect((try repo.verifyPremium("alex", "11111111-1111-4111-8111-111111111111")) == .deny);
    try idleAndUnlocked(&observer, &database.pool);
    try execute(&database.pool, "INSERT INTO users(discord_id,discord_username) VALUES ('synthetic-second','second'); INSERT INTO applications(user_id,minecraft_nickname,minecraft_nickname_normalized,client_type,about_me,discovery_source,status) SELECT id,'Other','other','licensed','test','test','approved' FROM users WHERE discord_id='synthetic-second'");
    try std.testing.expect((try repo.verifyPremium("other", "8667ba71-b85a-4004-af54-457a9734eed7")) == .deny);
    try idleAndUnlocked(&observer, &database.pool);
    // Force errors *after* the production binding UPDATE, proving rollback of
    // mutations as well as transaction release. Neither trigger duplicates auth.
    for ([_][]const u8{ "P0001", "23505" }) |sqlstate| {
        const trigger_sql = try std.fmt.allocPrint(std.testing.allocator, "CREATE FUNCTION evidence_failure() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'SYNTHETIC_QUERY_ERROR_SENTINEL' USING ERRCODE='{s}', CONSTRAINT='unrelated_evidence_constraint'; END $$; CREATE TRIGGER evidence_failure AFTER UPDATE ON game_identities FOR EACH ROW EXECUTE FUNCTION evidence_failure()", .{sqlstate});
        defer std.testing.allocator.free(trigger_sql);
        try execute(&database.pool, trigger_sql);
        try std.testing.expectError(error.QueryFailed, repo.verifyPremium("other", "11111111-1111-4111-8111-111111111111"));
        try idleAndUnlocked(&observer, &database.pool);
        try scalar(&observer, "SELECT licensed_mojang_uuid IS NULL FROM game_identities JOIN users ON users.id=game_identities.user_id WHERE discord_id='synthetic-second'", "t");
        try execute(&database.pool, "DROP TRIGGER evidence_failure ON game_identities; DROP FUNCTION evidence_failure()");
    }
    var next = try repo.verifyPremium("other", "11111111-1111-4111-8111-111111111111");
    if (next != .allow) return error.ExpectedPremiumIdentity;
    next.allow.deinit(std.testing.allocator);
    try idleAndUnlocked(&observer, &database.pool);
}

const LeaseRace = struct {
    pool: *db.Pool,
    identity: repository.Identity,
    token: [64]u8,
    refresh: bool,
    rejected: bool = false,
    failure: ?anyerror = null,

    fn run(self: *@This()) void {
        self.work() catch |err| {
            self.failure = err;
        };
    }
    fn work(self: *@This()) !void {
        var repo = repository.Repository.init(self.pool);
        if (self.refresh) {
            var decision = try repo.checkLease("server-a", &self.token);
            if (decision == .continue_session) decision.continue_session.identity.deinit(std.testing.allocator);
            self.rejected = decision == .disconnect;
        } else self.rejected = (try repo.issueLease("server-a", self.identity)) == null;
    }
};

fn waitForLock(observer: *db.Pool, pid: []const u8, event: ?[]const u8) !void {
    const start = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - start < 3000) {
        try execute(observer, "SELECT pg_stat_clear_snapshot()");
        var rows = try observer.query("SELECT wait_event_type,wait_event FROM pg_stat_activity WHERE pid=$1::integer", &.{pid});
        const waiting = rows.rowCount() == 1 and std.mem.eql(u8, rows.value(0, 0), "Lock") and (event == null or std.mem.eql(u8, rows.value(0, 1), event.?));
        rows.deinit();
        if (waiting) return;
        std.time.sleep(5 * std.time.ns_per_ms);
    }
    return error.ExpectedConcurrentLockWait;
}

test "two connection issue and refresh wait for mutation commit and reject stale authorization" {
    for ([_]bool{ false, true }) |refresh| {
        for ([_][]const u8{
            "UPDATE applications SET status='banned',decision_reason='synthetic'; UPDATE applications SET status='approved',decision_reason=NULL",
            "UPDATE password_credentials SET password_hash='synthetic-replacement'",
            "UPDATE applications SET minecraft_nickname='AlexTwo',minecraft_nickname_normalized='alextwo'",
            "UPDATE game_identities SET licensed_mojang_uuid=NULL",
        }, 0..) |mutation, mutation_index| {
            var database = try testDatabase();
            defer database.deinit();
            _ = try insertApplication(&database.pool, "Alex", "alex", if (mutation_index == 1) "cracked" else "licensed", "approved");
            var repo = repository.Repository.init(&database.pool);
            if (mutation_index == 1) {
                const hash = try domain.password.hashPassword(std.testing.allocator, "synthetic-race-password");
                defer std.testing.allocator.free(hash);
                var inserted = try database.pool.query("INSERT INTO password_credentials(user_id,password_hash) SELECT user_id,$1 FROM applications", &.{hash});
                inserted.deinit();
            }
            var identity = if (mutation_index == 1) blk: {
                const authenticated = try repo.authenticateCracked("alex", "synthetic-race-password");
                if (authenticated != .allow) return error.ExpectedCrackedIdentity;
                break :blk authenticated.allow;
            } else try licensed(&repo);
            defer identity.deinit(std.testing.allocator);
            const lease = (try repo.issueLease("server-a", identity)) orelse return error.ExpectedLease;
            var other = try db.Pool.open(std.testing.allocator, database.database_url);
            defer other.close();
            var pid = try other.query("SELECT pg_backend_pid()", &.{});
            defer pid.deinit();
            var transaction = try database.pool.begin();
            var committed = false;
            defer if (!committed) transaction.rollback() catch {};
            try execute(&database.pool, "SELECT id FROM users FOR UPDATE");
            try execute(&database.pool, mutation);
            var race = LeaseRace{ .pool = &other, .identity = identity, .token = lease.token, .refresh = refresh };
            const worker = try std.Thread.spawn(.{}, LeaseRace.run, .{&race});
            // Always release the transaction before joining on an assertion error.
            {
                defer worker.join();
                errdefer {
                    transaction.rollback() catch {};
                    committed = true;
                }
                try waitForLock(&database.pool, pid.value(0, 0), null);
                try transaction.commit();
                committed = true;
            }
            if (race.failure) |err| return err;
            try std.testing.expect(race.rejected);
            try idleAndUnlocked(&database.pool, &other);
        }
    }
}

const SnapshotRace = struct {
    pool: *db.Pool,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failure: ?anyerror = null,
    fn run(self: *@This()) void {
        self.work() catch |err| {
            self.failure = err;
        };
        self.done.store(true, .release);
    }
    fn work(self: *@This()) !void {
        for (0..100) |i| {
            try execute(self.pool, if (i % 2 == 0) "UPDATE applications SET minecraft_nickname='AlexTwo',minecraft_nickname_normalized='alextwo'" else "UPDATE applications SET minecraft_nickname='Alex',minecraft_nickname_normalized='alex'");
        }
    }
};

test "concurrent whitelist mutation never pairs rows with another committed version" {
    var database = try testDatabase();
    defer database.deinit();
    _ = try insertApplication(&database.pool, "Alex", "alex", "cracked", "approved");
    var repo = repository.Repository.init(&database.pool);
    const base = try repo.whitelistVersion();
    var other = try db.Pool.open(std.testing.allocator, database.database_url);
    defer other.close();
    var race = SnapshotRace{ .pool = &other };
    const worker = try std.Thread.spawn(.{}, SnapshotRace.run, .{&race});
    var during: usize = 0;
    {
        defer worker.join();
        for (0..200) |_| {
            const active = !race.done.load(.acquire);
            var snapshot = try repo.whitelistSnapshot(null);
            defer snapshot.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 1), snapshot.identities.len);
            const expected = if ((snapshot.version - base) % 2 == 1) "AlexTwo" else "Alex";
            try std.testing.expectEqualStrings(expected, snapshot.identities[0].nickname);
            if (active) during += 1;
        }
    }
    if (race.failure) |err| return err;
    try std.testing.expect(during > 0);
    try std.testing.expectEqual(base + 100, try repo.whitelistVersion());
}

const PremiumRace = struct {
    pool: *db.Pool,
    nickname: []const u8,
    allowed: bool = false,
    failure: ?anyerror = null,
    fn run(self: *@This()) void {
        self.work() catch |err| {
            self.failure = err;
        };
    }
    fn work(self: *@This()) !void {
        var repo = repository.Repository.init(self.pool);
        var decision = try repo.verifyPremium(self.nickname, "8667ba71-b85a-4004-af54-457a9734eed7");
        self.allowed = decision == .allow;
        if (decision == .allow) decision.allow.deinit(std.testing.allocator);
    }
};

test "concurrent premium UUID uniqueness conflict is generic denial and releases both transactions" {
    var database = try testDatabase();
    defer database.deinit();
    _ = try insertApplication(&database.pool, "Alex", "alex", "licensed", "approved");
    try execute(&database.pool, "INSERT INTO users(discord_id,discord_username) VALUES ('synthetic-second','second'); INSERT INTO applications(user_id,minecraft_nickname,minecraft_nickname_normalized,client_type,about_me,discovery_source,status) SELECT id,'Other','other','licensed','test','test','approved' FROM users WHERE discord_id='synthetic-second'");
    // A DB-only synchronization seam pauses both *real* UPDATEs after both
    // production prechecks. The actual unique index and exception helper decide
    // the winner. No query results/auth decisions are substituted.
    try execute(&database.pool, "CREATE FUNCTION evidence_barrier() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_advisory_xact_lock(67123619); RETURN NEW; END $$; CREATE TRIGGER evidence_barrier BEFORE UPDATE ON game_identities FOR EACH ROW EXECUTE FUNCTION evidence_barrier(); SELECT pg_advisory_lock(67123619)");
    var first = try db.Pool.open(std.testing.allocator, database.database_url);
    defer first.close();
    var second = try db.Pool.open(std.testing.allocator, database.database_url);
    defer second.close();
    var first_pid = try first.query("SELECT pg_backend_pid()", &.{});
    defer first_pid.deinit();
    var second_pid = try second.query("SELECT pg_backend_pid()", &.{});
    defer second_pid.deinit();
    var left = PremiumRace{ .pool = &first, .nickname = "alex" };
    var right = PremiumRace{ .pool = &second, .nickname = "other" };
    const left_worker = try std.Thread.spawn(.{}, PremiumRace.run, .{&left});
    {
        // Release advisory lock before joining even if setup/observation fails.
        defer left_worker.join();
        errdefer execute(&database.pool, "SELECT pg_advisory_unlock(67123619)") catch {};
        const right_worker = try std.Thread.spawn(.{}, PremiumRace.run, .{&right});
        {
            defer right_worker.join();
            defer execute(&database.pool, "SELECT pg_advisory_unlock(67123619)") catch {};
            try waitForLock(&database.pool, first_pid.value(0, 0), "advisory");
            try waitForLock(&database.pool, second_pid.value(0, 0), "advisory");
        }
    }
    if (left.failure) |err| return err;
    if (right.failure) |err| return err;
    try std.testing.expect(left.allowed != right.allowed);
    try scalar(&database.pool, "SELECT count(*) FROM game_identities WHERE licensed_mojang_uuid IS NOT NULL", "1");
    try idleAndUnlocked(&database.pool, &first);
    try idleAndUnlocked(&database.pool, &second);
}
