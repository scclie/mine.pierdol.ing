const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const pool_module = b.createModule(.{
        .root_source_file = b.path("src/db/pool.zig"),
        .target = target,
        .optimize = optimize,
    });
    const migration_files_module = addMigrationFilesModule(b);
    const password_deny_list_module = addPasswordDenyListModule(b);
    const migrations_module = b.createModule(.{
        .root_source_file = b.path("src/db/migrations.zig"),
        .target = target,
        .optimize = optimize,
    });
    migrations_module.addImport("db_pool", pool_module);
    migrations_module.addImport("migration_files", migration_files_module);

    const domain_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    domain_module.addImport("password_deny_list", password_deny_list_module);

    const config_module = b.createModule(.{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
    });
    const users_module = b.createModule(.{
        .root_source_file = b.path("src/db/users.zig"),
        .target = target,
        .optimize = optimize,
    });
    users_module.addImport("db_pool", pool_module);
    const auth_module = b.createModule(.{
        .root_source_file = b.path("src/services/auth.zig"),
        .target = target,
        .optimize = optimize,
    });
    auth_module.addImport("config", config_module);
    auth_module.addImport("users", users_module);
    auth_module.addImport("domain", domain_module);
    auth_module.addImport("db_pool", pool_module);

    const http_server_module = b.createModule(.{
        .root_source_file = b.path("src/http/server.zig"),
        .target = target,
        .optimize = optimize,
    });
    const runtime_module = b.createModule(.{
        .root_source_file = b.path("src/runtime.zig"),
        .target = target,
        .optimize = optimize,
    });
    const health_module = b.createModule(.{
        .root_source_file = b.path("src/routes/health.zig"),
        .target = target,
        .optimize = optimize,
    });
    health_module.addImport("http_server", http_server_module);
    const discord_module = b.createModule(.{
        .root_source_file = b.path("src/services/discord.zig"),
        .target = target,
        .optimize = optimize,
    });
    discord_module.addImport("config", config_module);
    discord_module.addImport("db_pool", pool_module);
    const applications_module = b.createModule(.{
        .root_source_file = b.path("src/db/applications.zig"),
        .target = target,
        .optimize = optimize,
    });
    applications_module.addImport("db_pool", pool_module);
    applications_module.addImport("domain", domain_module);
    applications_module.addImport("auth", auth_module);
    applications_module.addImport("users", users_module);
    const application_service_module = b.createModule(.{
        .root_source_file = b.path("src/services/applications.zig"),
        .target = target,
        .optimize = optimize,
    });
    application_service_module.addImport("db_pool", pool_module);
    application_service_module.addImport("domain", domain_module);
    application_service_module.addImport("auth", auth_module);
    application_service_module.addImport("applications_repository", applications_module);
    const account_routes_module = b.createModule(.{
        .root_source_file = b.path("src/routes/account.zig"),
        .target = target,
        .optimize = optimize,
    });
    account_routes_module.addImport("config", config_module);
    account_routes_module.addImport("auth", auth_module);
    account_routes_module.addImport("db_pool", pool_module);
    account_routes_module.addImport("application_service", application_service_module);
    account_routes_module.addImport("http_server", http_server_module);
    const admin_routes_module = b.createModule(.{
        .root_source_file = b.path("src/routes/admin.zig"),
        .target = target,
        .optimize = optimize,
    });
    admin_routes_module.addImport("config", config_module);
    admin_routes_module.addImport("auth", auth_module);
    admin_routes_module.addImport("db_pool", pool_module);
    admin_routes_module.addImport("domain", domain_module);
    admin_routes_module.addImport("application_service", application_service_module);
    admin_routes_module.addImport("http_server", http_server_module);
    admin_routes_module.addImport("account_routes", account_routes_module);
    const auth_routes_module = b.createModule(.{
        .root_source_file = b.path("src/routes/auth.zig"),
        .target = target,
        .optimize = optimize,
    });
    auth_routes_module.addImport("config", config_module);
    auth_routes_module.addImport("auth", auth_module);
    auth_routes_module.addImport("discord", discord_module);
    auth_routes_module.addImport("http_server", http_server_module);
    auth_routes_module.addImport("account_routes", account_routes_module);
    auth_routes_module.addImport("admin_routes", admin_routes_module);

    const exe = b.addExecutable(.{
        .name = "mine-api",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("db_pool", pool_module);
    exe.root_module.addImport("domain", domain_module);
    exe.root_module.addImport("migration_files", migration_files_module);
    exe.root_module.addImport("config", config_module);
    exe.root_module.addImport("http_server", http_server_module);
    exe.root_module.addImport("discord", discord_module);
    exe.root_module.addImport("auth_routes", auth_routes_module);
    exe.root_module.addImport("health", health_module);
    exe.root_module.addImport("runtime", runtime_module);
    exe.linkLibC();
    exe.linkSystemLibrary("pq");
    b.installArtifact(exe);

    const release_server = b.addTest(.{
        .name = "release-api",
        .root_source_file = b.path("test/release_server.zig"),
        .target = target,
        .optimize = optimize,
        .filters = &.{"release_server"},
    });
    release_server.root_module.addImport("db_pool", pool_module);
    release_server.root_module.addImport("config", config_module);
    release_server.root_module.addImport("http_server", http_server_module);
    release_server.root_module.addImport("discord", discord_module);
    release_server.root_module.addImport("auth_routes", auth_routes_module);
    release_server.root_module.addImport("health", health_module);
    release_server.root_module.addImport("migrations", migrations_module);
    release_server.linkLibC();
    release_server.linkSystemLibrary("pq");
    const install_release = b.addInstallArtifact(release_server, .{});
    b.step("release-server", "Build only the isolated release test server").dependOn(&install_release.step);

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .filters = b.args orelse &.{},
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    unit_tests.root_module.addImport("password_deny_list", password_deny_list_module);

    const domain_tests = b.addTest(.{
        .root_source_file = b.path("test/domain_application_test.zig"),
        .target = target,
        .optimize = optimize,
        .filters = b.args orelse &.{},
    });
    domain_tests.root_module.addImport("domain", domain_module);
    const run_domain_tests = b.addRunArtifact(domain_tests);

    const migration_tests = b.addTest(.{
        .root_source_file = b.path("test/migrations_test.zig"),
        .target = target,
        .optimize = optimize,
        .filters = b.args orelse &.{},
    });
    migration_tests.root_module.addImport("db_pool", pool_module);
    migration_tests.root_module.addImport("migrations", migrations_module);
    migration_tests.linkLibC();
    migration_tests.linkSystemLibrary("pq");
    const run_migration_tests = b.addRunArtifact(migration_tests);

    const password_tests = b.addTest(.{
        .root_source_file = b.path("test/password_test.zig"),
        .target = target,
        .optimize = optimize,
        .filters = b.args orelse &.{},
    });
    password_tests.root_module.addImport("db_pool", pool_module);
    password_tests.root_module.addImport("migrations", migrations_module);
    password_tests.root_module.addImport("domain", domain_module);
    password_tests.root_module.addImport("applications", applications_module);
    password_tests.linkLibC();
    password_tests.linkSystemLibrary("pq");
    const run_password_tests = b.addRunArtifact(password_tests);

    const auth_tests = b.addTest(.{
        .root_source_file = b.path("test/auth_service_test.zig"),
        .target = target,
        .optimize = optimize,
        .filters = b.args orelse &.{},
    });
    auth_tests.root_module.addImport("config", config_module);
    auth_tests.root_module.addImport("auth", auth_module);
    auth_tests.root_module.addImport("db_pool", pool_module);
    auth_tests.root_module.addImport("migrations", migrations_module);
    const postgres_module = b.createModule(.{
        .root_source_file = b.path("test/support/postgres.zig"),
        .target = target,
        .optimize = optimize,
    });
    postgres_module.addImport("db_pool", pool_module);
    auth_tests.root_module.addImport("postgres", postgres_module);
    auth_tests.linkLibC();
    auth_tests.linkSystemLibrary("pq");
    const run_auth_tests = b.addRunArtifact(auth_tests);

    const oauth_route_tests = b.addTest(.{
        .root_source_file = b.path("test/oauth_route_test.zig"),
        .target = target,
        .optimize = optimize,
        .filters = b.args orelse &.{},
    });
    oauth_route_tests.root_module.addImport("config", config_module);
    oauth_route_tests.root_module.addImport("db_pool", pool_module);
    oauth_route_tests.root_module.addImport("migrations", migrations_module);
    oauth_route_tests.root_module.addImport("postgres", postgres_module);
    oauth_route_tests.root_module.addImport("http_server", http_server_module);
    oauth_route_tests.root_module.addImport("discord", discord_module);
    oauth_route_tests.root_module.addImport("auth_routes", auth_routes_module);
    oauth_route_tests.linkLibC();
    oauth_route_tests.linkSystemLibrary("pq");
    const run_oauth_route_tests = b.addRunArtifact(oauth_route_tests);

    const account_route_tests = b.addTest(.{
        .root_source_file = b.path("test/account_routes_test.zig"),
        .target = target,
        .optimize = optimize,
        .filters = b.args orelse &.{},
    });
    account_route_tests.root_module.addImport("config", config_module);
    account_route_tests.root_module.addImport("auth", auth_module);
    account_route_tests.root_module.addImport("domain", domain_module);
    account_route_tests.root_module.addImport("migrations", migrations_module);
    account_route_tests.root_module.addImport("postgres", postgres_module);
    account_route_tests.root_module.addImport("http_server", http_server_module);
    account_route_tests.root_module.addImport("discord", discord_module);
    account_route_tests.root_module.addImport("auth_routes", auth_routes_module);
    account_route_tests.linkLibC();
    account_route_tests.linkSystemLibrary("pq");
    const run_account_route_tests = b.addRunArtifact(account_route_tests);

    const admin_route_tests = b.addTest(.{
        .root_source_file = b.path("test/admin_routes_test.zig"),
        .target = target,
        .optimize = optimize,
        .filters = b.args orelse &.{},
    });
    admin_route_tests.root_module.addImport("config", config_module);
    admin_route_tests.root_module.addImport("auth", auth_module);
    admin_route_tests.root_module.addImport("domain", domain_module);
    admin_route_tests.root_module.addImport("db_pool", pool_module);
    admin_route_tests.root_module.addImport("migrations", migrations_module);
    admin_route_tests.root_module.addImport("postgres", postgres_module);
    admin_route_tests.root_module.addImport("http_server", http_server_module);
    admin_route_tests.root_module.addImport("discord", discord_module);
    admin_route_tests.root_module.addImport("auth_routes", auth_routes_module);
    admin_route_tests.linkLibC();
    admin_route_tests.linkSystemLibrary("pq");
    const run_admin_route_tests = b.addRunArtifact(admin_route_tests);

    const pool_tests = b.addTest(.{
        .root_source_file = b.path("src/db/pool.zig"),
        .target = target,
        .optimize = optimize,
        .filters = b.args orelse &.{},
    });
    pool_tests.linkLibC();
    pool_tests.linkSystemLibrary("pq");
    const run_pool_tests = b.addRunArtifact(pool_tests);

    const wire_tests = b.addTest(.{
        .root_source_file = b.path("src/http/server.zig"),
        .target = target,
        .optimize = optimize,
        .filters = b.args orelse &.{},
    });
    const run_wire_tests = b.addRunArtifact(wire_tests);

    const runtime_tests = b.addTest(.{
        .root_source_file = b.path("test/runtime_test.zig"),
        .target = target,
        .optimize = optimize,
        .filters = b.args orelse &.{},
    });
    runtime_tests.root_module.addImport("runtime", runtime_module);
    const run_runtime_tests = b.addRunArtifact(runtime_tests);

    const health_route_tests = b.addTest(.{
        .root_source_file = b.path("test/health_route_test.zig"),
        .target = target,
        .optimize = optimize,
        .filters = b.args orelse &.{},
    });
    health_route_tests.root_module.addImport("http_server", http_server_module);
    health_route_tests.root_module.addImport("health", health_module);
    const run_health_route_tests = b.addRunArtifact(health_route_tests);

    const response_tests = b.addTest(.{
        .root_source_file = b.path("src/http/response.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .filters = b.args orelse &.{},
    });
    const run_response_tests = b.addRunArtifact(response_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_response_tests.step);
    test_step.dependOn(&run_wire_tests.step);
    test_step.dependOn(&run_runtime_tests.step);
    test_step.dependOn(&run_health_route_tests.step);
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_domain_tests.step);
    test_step.dependOn(&run_migration_tests.step);
    test_step.dependOn(&run_password_tests.step);
    test_step.dependOn(&run_auth_tests.step);
    test_step.dependOn(&run_oauth_route_tests.step);
    test_step.dependOn(&run_account_route_tests.step);
    test_step.dependOn(&run_admin_route_tests.step);
    test_step.dependOn(&run_pool_tests.step);
}

fn addMigrationFilesModule(b: *std.Build) *std.Build.Module {
    var directory = std.fs.cwd().openDir("db/migrations", .{ .iterate = true }) catch |err| {
        std.debug.panic("unable to open db/migrations: {s}", .{@errorName(err)});
    };
    defer directory.close();

    var names = std.ArrayList([]const u8).init(b.allocator);
    var iterator = directory.iterate();
    while (iterator.next() catch |err| std.debug.panic("unable to read db/migrations: {s}", .{@errorName(err)})) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".sql")) {
            names.append(b.dupe(entry.name)) catch |err| std.debug.panic("unable to read migration names: {s}", .{@errorName(err)});
        }
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);

    const write_files = b.addWriteFiles();
    var source = std.ArrayList(u8).init(b.allocator);
    source.appendSlice("pub const Migration = struct { version: []const u8, sql: []const u8 };\npub const files = [_]Migration{\n") catch |err| std.debug.panic("unable to generate migration module: {s}", .{@errorName(err)});
    for (names.items) |name| {
        _ = write_files.addCopyFile(b.path(b.fmt("db/migrations/{s}", .{name})), name);
        const version = name[0 .. name.len - ".sql".len];
        source.writer().print("    .{{ .version = \"{s}\", .sql = @embedFile(\"{s}\") }},\n", .{ version, name }) catch |err| std.debug.panic("unable to generate migration module: {s}", .{@errorName(err)});
    }
    source.appendSlice("};\n") catch |err| std.debug.panic("unable to generate migration module: {s}", .{@errorName(err)});

    return b.createModule(.{
        .root_source_file = write_files.add("migration_files.zig", source.items),
    });
}

fn addPasswordDenyListModule(b: *std.Build) *std.Build.Module {
    const write_files = b.addWriteFiles();
    _ = write_files.addCopyFile(b.path("assets/password-deny-list.txt"), "password-deny-list.txt");
    return b.createModule(.{
        .root_source_file = write_files.add("password_deny_list.zig", "pub const contents = @embedFile(\"password-deny-list.txt\");\n"),
    });
}

fn lessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}
