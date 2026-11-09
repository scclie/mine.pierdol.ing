const db = @import("db_pool");
const migration_files = @import("migration_files");

fn unlock(pool: *db.Pool) void {
    var unlock_result = pool.query("SELECT pg_advisory_unlock($1)", &.{"763214841"}) catch return;
    unlock_result.deinit();
}

pub fn apply(pool: *db.Pool) !void {
    var lock_result = try pool.query("SELECT pg_advisory_lock($1)", &.{"763214841"});
    lock_result.deinit();
    defer unlock(pool);

    var schema_result = try pool.query(
        "CREATE TABLE IF NOT EXISTS schema_migrations (version TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now())",
        &.{},
    );
    schema_result.deinit();

    for (migration_files.files) |migration| {
        var applied_result = try pool.query(
            "SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE version = $1)",
            &.{migration.version},
        );
        defer applied_result.deinit();
        if (applied_result.value(0, 0)[0] == 't') continue;

        var transaction = try pool.begin();
        errdefer transaction.rollback() catch {};

        var migration_result = try transaction.query(migration.sql, &.{});
        migration_result.deinit();

        var record_result = try transaction.query(
            "INSERT INTO schema_migrations (version) VALUES ($1)",
            &.{migration.version},
        );
        record_result.deinit();

        try transaction.commit();
    }
}
