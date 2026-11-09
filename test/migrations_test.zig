const std = @import("std");
const migrations = @import("migrations");
const postgres = @import("support/postgres.zig");

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
}
