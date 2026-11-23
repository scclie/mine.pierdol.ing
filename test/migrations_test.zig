const std = @import("std");
const migrations = @import("migrations");
const postgres = @import("support/postgres.zig");
const db = @import("db_pool");
const migration_files = @import("migration_files");

test "migrations_test applies the initial schema exactly once" {
    const admin_database_url = std.posix.getenv("TEST_DATABASE_URL") orelse return error.TestDatabaseUrlNotConfigured;

    var test_database = try postgres.TestDatabase.create(std.testing.allocator, admin_database_url);
    defer test_database.deinit();

    try migrations.apply(&test_database.pool);

    const relations = [_][]const u8{
        "schema_migrations",
        "users",
        "applications",
        "password_credentials",
        "web_sessions",
        "oauth_states",
        "audit_log",
    };
    for (relations) |relation| {
        var result = try test_database.pool.query(
            "SELECT to_regclass($1) IS NOT NULL",
            &.{relation},
        );
        defer result.deinit();
        try std.testing.expectEqualStrings("t", result.value(0, 0));
    }

    try migrations.apply(&test_database.pool);
    var migration_result = try test_database.pool.query(
        "SELECT count(*) FROM schema_migrations WHERE version = $1",
        &.{"001_initial"},
    );
    defer migration_result.deinit();
    try std.testing.expectEqualStrings("1", migration_result.value(0, 0));
    try expectSql(&test_database.pool, "SELECT count(*) FROM schema_migrations WHERE version='003_licensed_uuid_lifecycle'", "1");
}

fn exec(pool: *db.Pool, sql: []const u8) !void {
    var result = try pool.query(sql, &.{});
    defer result.deinit();
}

fn expectSql(pool: *db.Pool, sql: []const u8, expected: []const u8) !void {
    var result = try pool.query(sql, &.{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.rowCount());
    try std.testing.expectEqualStrings(expected, result.value(0, 0));
}

fn seed(pool: *db.Pool) !void {
    try exec(pool,
        \\INSERT INTO users(discord_id,discord_username) VALUES ('fixture-one','one'),('fixture-two','two'),('fixture-three','three');
        \\INSERT INTO applications(user_id,minecraft_nickname,minecraft_nickname_normalized,client_type,about_me,discovery_source,status)
        \\VALUES (1,'One','one','licensed','fixture','fixture','pending'),
        \\       (2,'Two','two','licensed','fixture','fixture','approved'),
        \\       (3,'Three','three','licensed','fixture','fixture','approved');
        \\SELECT game_auth_set_identity_uuid(2,'11111111-1111-1111-1111-111111111111');
    );
}

test "migrations_test lifecycle upgrade" {
    const url = std.posix.getenv("TEST_DATABASE_URL") orelse return error.TestDatabaseUrlNotConfigured;
    var database = try postgres.TestDatabase.create(std.testing.allocator, url);
    defer database.deinit();
    const pool = &database.pool;
    try exec(pool, "CREATE TABLE schema_migrations(version TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now())");
    var applied: usize = 0;
    for (migration_files.files) |migration| {
        if (!std.mem.eql(u8, migration.version, "001_initial") and !std.mem.eql(u8, migration.version, "002_game_auth")) continue;
        try exec(pool, migration.sql);
        var result = try pool.query("INSERT INTO schema_migrations(version) VALUES ($1)", &.{migration.version});
        result.deinit();
        applied += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), applied);
    try seed(pool);
    try exec(pool,
        \\CREATE TEMP TABLE legacy_identities AS SELECT * FROM game_identities;
        \\CREATE TEMP TABLE legacy_applications AS SELECT * FROM applications;
        \\CREATE TEMP TABLE legacy_constraint AS SELECT oid FROM pg_constraint WHERE conname='game_identities_licensed_mojang_uuid_key';
        \\CREATE TEMP TABLE legacy_cursor AS SELECT version FROM game_auth_whitelist_state;
    );
    try migrations.apply(pool);
    try expectSql(pool, "SELECT application_revision > 0 FROM users WHERE id=1", "t");
    try expectSql(pool, "SELECT bool_and(application_revision=1) FROM users", "t");
    try expectSql(pool, "SELECT NOT EXISTS ((TABLE legacy_identities EXCEPT TABLE game_identities) UNION ALL (TABLE game_identities EXCEPT TABLE legacy_identities))", "t");
    try expectSql(pool, "SELECT NOT EXISTS ((TABLE legacy_applications EXCEPT TABLE applications) UNION ALL (TABLE applications EXCEPT TABLE legacy_applications))", "t");
    try expectSql(pool, "SELECT oid=(SELECT oid FROM legacy_constraint) FROM pg_constraint WHERE conname='game_identities_licensed_mojang_uuid_key'", "t");
    try expectSql(pool, "SELECT version=(SELECT version FROM legacy_cursor) FROM game_auth_whitelist_state", "t");
    try migrations.apply(pool);
    try expectSql(pool, "SELECT count(*) FROM schema_migrations", "4");
    try expectSql(pool, "SELECT count(*) FROM schema_migrations WHERE version='003_licensed_uuid_lifecycle'", "1");
    try expectSql(pool, "SELECT bool_and(application_revision=1) FROM users", "t");
}

fn capture(pool: *db.Pool) !void {
    try exec(pool,
        \\DROP TABLE IF EXISTS lifecycle_before;
        \\CREATE TEMP TABLE lifecycle_before AS SELECT u.application_revision AS revision,i.identity_id,i.authentication_generation AS generation,s.version AS cursor
        \\FROM users u JOIN game_identities i ON i.user_id=u.id CROSS JOIN game_auth_whitelist_state s WHERE u.id=1;
    );
}

fn expectState(pool: *db.Pool, changed: bool) !void {
    try expectSql(pool, if (changed)
        \\SELECT u.application_revision>b.revision AND i.authentication_generation>b.generation AND s.version>b.cursor AND i.identity_id=b.identity_id
        \\FROM users u JOIN game_identities i ON i.user_id=u.id CROSS JOIN game_auth_whitelist_state s CROSS JOIN lifecycle_before b WHERE u.id=1
    else
        \\SELECT u.application_revision=b.revision AND i.authentication_generation=b.generation AND s.version=b.cursor AND i.identity_id=b.identity_id
        \\FROM users u JOIN game_identities i ON i.user_id=u.id CROSS JOIN game_auth_whitelist_state s CROSS JOIN lifecycle_before b WHERE u.id=1
    , "t");
}

test "migrations_test UUID setter revision" {
    const url = std.posix.getenv("TEST_DATABASE_URL") orelse return error.TestDatabaseUrlNotConfigured;
    var database = try postgres.TestDatabase.create(std.testing.allocator, url);
    defer database.deinit();
    const pool = &database.pool;
    try migrations.apply(pool);
    try seed(pool);
    try expectSql(pool, "SELECT application_set_licensed_uuid(999,NULL)", "missing");
    try expectSql(pool, "SELECT application_revision>0 FROM users WHERE id=1", "t");
    try capture(pool);
    try expectSql(pool, "SELECT application_set_licensed_uuid(1,'4af7fe6c-cb9e-4012-bef8-adf078f34694'::uuid)", "updated");
    try expectSql(pool, "SELECT licensed_mojang_uuid::text FROM game_identities WHERE user_id=1", "4af7fe6c-cb9e-4012-bef8-adf078f34694");
    try expectState(pool, true);
    try capture(pool);
    try expectSql(pool, "SELECT application_set_licensed_uuid(1,'4af7fe6c-cb9e-4012-bef8-adf078f34694')", "updated");
    try expectState(pool, false);
    var transaction = try pool.begin();
    errdefer transaction.rollback() catch {};
    try expectSql(pool, "SELECT application_set_licensed_uuid(1,'22222222-2222-2222-2222-222222222222')", "updated");
    try expectState(pool, true);
    try transaction.rollback();
    try expectState(pool, false);
    try expectSql(pool, "SELECT licensed_mojang_uuid::text FROM game_identities WHERE user_id=1", "4af7fe6c-cb9e-4012-bef8-adf078f34694");
    try expectSql(pool, "SELECT application_set_licensed_uuid(1,'11111111-1111-1111-1111-111111111111')", "in_use");
    try expectState(pool, false);
    try expectSql(pool, "SELECT licensed_mojang_uuid::text FROM game_identities WHERE user_id=2", "11111111-1111-1111-1111-111111111111");
    try expectSql(pool, "SELECT application_set_licensed_uuid(999,NULL)", "missing");
    try exec(pool,
        \\CREATE FUNCTION fixture_unrelated_unique() RETURNS TRIGGER LANGUAGE plpgsql AS $$ BEGIN
        \\RAISE unique_violation USING CONSTRAINT='fixture_unrelated_unique_key'; END; $$;
        \\CREATE TRIGGER fixture_unrelated_unique BEFORE UPDATE ON game_identities FOR EACH ROW EXECUTE FUNCTION fixture_unrelated_unique();
    );
    try std.testing.expectError(error.QueryFailed, pool.query("SELECT application_set_licensed_uuid(1,NULL)", &.{}));
    try exec(pool, "DROP TRIGGER fixture_unrelated_unique ON game_identities; DROP FUNCTION fixture_unrelated_unique()");
    try expectState(pool, false);
    try expectSql(pool, "SELECT application_set_licensed_uuid(1,NULL)", "updated");
    try expectState(pool, true);
    try expectSql(pool, "SELECT licensed_mojang_uuid IS NULL FROM game_identities WHERE user_id=1", "t");
    try exec(pool, "SELECT game_auth_delete_identity(1)");
    try expectSql(pool, "SELECT application_set_licensed_uuid(1,NULL)", "missing");
}

test "migrations_test durable revision mutation coverage and ABA" {
    const url = std.posix.getenv("TEST_DATABASE_URL") orelse return error.TestDatabaseUrlNotConfigured;
    var database = try postgres.TestDatabase.create(std.testing.allocator, url);
    defer database.deinit();
    const pool = &database.pool;
    try migrations.apply(pool);
    try seed(pool);
    // verify dependent-row triggers and generation after recreation
    // check exact deltas so identity updates cannot hide missing credential triggers
    const Mutation = struct { sql: []const u8, delta: []const u8 };
    const mutations = [_]Mutation{
        .{ .sql = "UPDATE applications SET about_me=about_me WHERE user_id=1", .delta = "1" },
        .{ .sql = "UPDATE applications SET about_me='changed' WHERE user_id=1; UPDATE applications SET about_me='fixture' WHERE user_id=1", .delta = "2" },
        .{ .sql = "UPDATE game_identities SET authentication_generation=authentication_generation WHERE user_id=1", .delta = "1" },
        .{ .sql = "INSERT INTO password_credentials(user_id,password_hash) VALUES (1,'non-secret-test-placeholder')", .delta = "2" },
        .{ .sql = "UPDATE password_credentials SET password_hash=password_hash WHERE user_id=1", .delta = "2" },
        .{ .sql = "DELETE FROM password_credentials WHERE user_id=1", .delta = "2" },
        .{ .sql = "UPDATE users SET discord_id='fixture-replacement' WHERE id=1; UPDATE users SET discord_id='fixture-one' WHERE id=1", .delta = "2" },
        .{ .sql = "SELECT game_auth_bind_premium(1,'22222222-2222-2222-2222-222222222222')", .delta = "1" },
        .{ .sql = "SELECT game_auth_set_identity_uuid(1,NULL)", .delta = "1" },
        .{ .sql = "SELECT game_auth_delete_identity(1)", .delta = "1" },
        .{ .sql = "INSERT INTO game_identities(user_id) VALUES (1)", .delta = "1" },
        .{ .sql = "DELETE FROM applications WHERE user_id=1", .delta = "2" },
        .{ .sql = "INSERT INTO applications(user_id,minecraft_nickname,minecraft_nickname_normalized,client_type,about_me,discovery_source) VALUES (1,'One','one','licensed','fixture','fixture')", .delta = "2" },
    };
    for (mutations) |mutation| {
        try exec(pool, "CREATE TEMP TABLE revision_before AS SELECT application_revision FROM users WHERE id=1");
        try exec(pool, mutation.sql);
        try expectSql(pool, "SELECT application_revision-(SELECT application_revision FROM revision_before) FROM users WHERE id=1", mutation.delta);
        try exec(pool, "DROP TABLE revision_before");
    }
    try capture(pool);
    try exec(pool, "UPDATE users SET discord_id=discord_id,discord_username='renamed' WHERE id=1");
    try expectState(pool, false);
    var transaction = try pool.begin();
    errdefer transaction.rollback() catch {};
    try exec(pool, "DELETE FROM applications WHERE user_id=1; UPDATE users SET discord_id='temporary' WHERE id=1");
    try transaction.rollback();
    try expectState(pool, false);
    try std.testing.expectError(error.QueryFailed, pool.query("UPDATE users SET application_revision=0 WHERE id=1", &.{}));
    try std.testing.expectError(error.QueryFailed, pool.query("UPDATE users SET application_revision=NULL WHERE id=1", &.{}));
}
