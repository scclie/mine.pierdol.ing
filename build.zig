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

    const mojang_module = b.createModule(.{ .root_source_file = b.path("src/services/mojang.zig"), .target = target, .optimize = optimize });
    mojang_module.addImport("domain", domain_module);
    const fake_mojang_module = b.createModule(.{ .root_source_file = b.path("test/support/mojang.zig"), .target = target, .optimize = optimize });
    fake_mojang_module.addImport("domain", domain_module);
    fake_mojang_module.addImport("mojang", mojang_module);
    const mojang_options = b.addOptions();
    inline for (.{ .{ "mojang-ca-bundle", "MOJANG_CA_BUNDLE", "ca_bundle" }, .{ "mojang-curl-version", "MOJANG_CURL_VERSION", "curl_version" }, .{ "mojang-ares-version", "MOJANG_ARES_VERSION", "ares_version" }, .{ "mojang-openssl-version", "MOJANG_OPENSSL_VERSION", "openssl_version" } }) |entry| {
        const value = b.option([]const u8, entry[0], "Selected Task 3A build metadata") orelse b.graph.env_map.get(entry[1]) orelse "";
        mojang_options.addOption([]const u8, entry[2], value);
    }
    const mojang_transport_module = b.createModule(.{ .root_source_file = b.path("src/services/mojang_transport.zig"), .target = target, .optimize = optimize });
    mojang_transport_module.addImport("domain", domain_module);
    mojang_transport_module.addImport("mojang", mojang_module);
    const mojang_build_module = mojang_options.createModule();
    mojang_transport_module.addImport("mojang_build", mojang_build_module);
    const mojang_tests = b.addTest(.{ .root_source_file = b.path("test/mojang_test.zig"), .target = target, .optimize = optimize, .filters = b.args orelse &.{} });
    mojang_tests.root_module.addImport("domain", domain_module);
    mojang_tests.root_module.addImport("mojang", mojang_module);
    mojang_tests.root_module.addImport("fake_mojang", fake_mojang_module);
    const run_mojang = b.addRunArtifact(mojang_tests);
    b.step("test-mojang", "Run DB-free resolver policy tests").dependOn(&run_mojang.step);
    const transport_support = b.createModule(.{ .root_source_file = b.path("test/support/mojang_transport.zig"), .target = target, .optimize = optimize });
    transport_support.addImport("mojang", mojang_module);
    transport_support.addImport("domain", domain_module);
    transport_support.addImport("mojang_transport", mojang_transport_module);
    const transport_tests = transportTests(b, "test", target, optimize, b.args orelse &.{}, domain_module, mojang_module, mojang_transport_module, transport_support, mojang_build_module);
    b.step("check-mojang-transport", "Compile only the isolated transport tests").dependOn(&transport_tests.step);
    b.step("test-mojang-transport", "Explicit DB-free transport tests").dependOn(&b.addRunArtifact(transport_tests).step);
    const install_transport = b.step("install-mojang-transport-tests", "Install fixed-filter DB-free transport test artifacts only");
    inline for (.{ .{ "mojang-transport-capability-tests", "mojang transport dependency" }, .{ "mojang-transport-tests", "mojang transport" } }) |entry| {
        const artifact = transportTests(b, entry[0], target, optimize, &.{entry[1]}, domain_module, mojang_module, mojang_transport_module, transport_support, mojang_build_module);
        install_transport.dependOn(&b.addInstallArtifact(artifact, .{}).step);
    }

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
    const game_auth_repository_module = b.createModule(.{
        .root_source_file = b.path("src/db/game_auth.zig"),
        .target = target,
        .optimize = optimize,
    });
    game_auth_repository_module.addImport("db_pool", pool_module);
    game_auth_repository_module.addImport("domain", domain_module);
    const game_auth_service_module = b.createModule(.{
        .root_source_file = b.path("src/services/game_auth.zig"),
        .target = target,
        .optimize = optimize,
    });
    game_auth_service_module.addImport("db_pool", pool_module);
    game_auth_service_module.addImport("domain", domain_module);
    game_auth_service_module.addImport("game_auth_repository", game_auth_repository_module);
    const playtime_repository_module = b.createModule(.{
        .root_source_file = b.path("src/db/playtime.zig"),
        .target = target,
        .optimize = optimize,
    });
    playtime_repository_module.addImport("db_pool", pool_module);
    const playtime_service_module = b.createModule(.{
        .root_source_file = b.path("src/services/playtime.zig"),
        .target = target,
        .optimize = optimize,
    });
    playtime_service_module.addImport("db_pool", pool_module);
    playtime_service_module.addImport("playtime_repository", playtime_repository_module);
    const game_auth_routes_module = b.createModule(.{
        .root_source_file = b.path("src/routes/game_auth.zig"),
        .target = target,
        .optimize = optimize,
    });
    game_auth_routes_module.addImport("config", config_module);
    game_auth_routes_module.addImport("db_pool", pool_module);
    game_auth_routes_module.addImport("game_auth_service", game_auth_service_module);
    game_auth_routes_module.addImport("http_server", http_server_module);
    const active_minutes_module = b.createModule(.{
        .root_source_file = b.path("src/routes/active_minutes.zig"),
        .target = target,
        .optimize = optimize,
    });
    active_minutes_module.addImport("db_pool", pool_module);
    active_minutes_module.addImport("http_server", http_server_module);
    active_minutes_module.addImport("playtime_service", playtime_service_module);
    const runtime_module = b.createModule(.{
        .root_source_file = b.path("src/runtime.zig"),
        .target = target,
        .optimize = optimize,
    });
    runtime_module.addImport("game_auth_routes", game_auth_routes_module);
    runtime_module.addImport("http_server", http_server_module);
    const health_module = b.createModule(.{
        .root_source_file = b.path("src/routes/health.zig"),
        .target = target,
        .optimize = optimize,
    });
    health_module.addImport("http_server", http_server_module);
    const public_servers_module = b.createModule(.{
        .root_source_file = b.path("src/routes/public_servers.zig"),
        .target = target,
        .optimize = optimize,
    });
    public_servers_module.addImport("http_server", http_server_module);
    public_servers_module.addImport("db_pool", pool_module);
    public_servers_module.addImport("config", config_module);
    public_servers_module.addImport("mojang_build", mojang_build_module);
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
    applications_module.addImport("mojang", mojang_module);
    const application_service_module = b.createModule(.{
        .root_source_file = b.path("src/services/applications.zig"),
        .target = target,
        .optimize = optimize,
    });
    application_service_module.addImport("db_pool", pool_module);
    application_service_module.addImport("domain", domain_module);
    application_service_module.addImport("auth", auth_module);
    application_service_module.addImport("mojang", mojang_module);
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
    for ([_]*std.Build.Module{ account_routes_module, admin_routes_module, auth_routes_module }) |module| module.addImport("mojang", mojang_module);

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
    exe.root_module.addImport("game_auth_routes", game_auth_routes_module);
    exe.root_module.addImport("active_minutes", active_minutes_module);
    exe.root_module.addImport("health", health_module);
    exe.root_module.addImport("public_servers", public_servers_module);
    exe.root_module.addImport("runtime", runtime_module);
    exe.root_module.addImport("mojang", mojang_module);
    exe.root_module.addImport("mojang_transport", mojang_transport_module);
    const metadata_source = b.addWriteFiles().add("mojang_metadata.zig",
        \\const build = @import("mojang_build");
        \\pub export const mojang_transport_build_metadata = ("MOJANG_BUILD\n" ++ build.ca_bundle ++ "\n" ++ build.curl_version ++ "\n" ++ build.ares_version ++ "\n" ++ build.openssl_version ++ "\n").*;
    );
    const metadata_object = b.addObject(.{ .name = "mojang-build-metadata", .root_source_file = metadata_source, .target = target, .optimize = optimize });
    metadata_object.root_module.addImport("mojang_build", mojang_build_module);
    // this object is already compiled with mojang_build.
    exe.addObjectFile(metadata_object.getEmittedBin());
    exe.forceUndefinedSymbol("mojang_transport_build_metadata");
    exe.linkLibC();
    exe.linkSystemLibrary("pq");
    exe.linkSystemLibrary2("curl", .{ .use_pkg_config = .no, .needed = true });
    exe.linkSystemLibrary2("ssl", .{ .use_pkg_config = .no, .needed = true });
    exe.linkSystemLibrary2("crypto", .{ .use_pkg_config = .no, .needed = true });
    transportRPaths(b, exe, true);
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
    migration_tests.root_module.addImport("migration_files", migration_files_module);
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
    password_tests.root_module.addImport("application_service", application_service_module);
    password_tests.root_module.addImport("mojang", mojang_module);
    password_tests.root_module.addImport("fake_mojang", fake_mojang_module);
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
    const application_repository_tests = b.addTest(.{
        .root_source_file = b.path("test/application_repository_test.zig"),
        .target = target,
        .optimize = optimize,
        .filters = b.args orelse &.{},
    });
    application_repository_tests.root_module.addImport("applications", applications_module);
    application_repository_tests.root_module.addImport("db_pool", pool_module);
    application_repository_tests.root_module.addImport("domain", domain_module);
    application_repository_tests.root_module.addImport("migrations", migrations_module);
    application_repository_tests.root_module.addImport("postgres", postgres_module);
    application_repository_tests.linkLibC();
    application_repository_tests.linkSystemLibrary("pq");
    const run_application_repository_tests = b.addRunArtifact(application_repository_tests);
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
    account_route_tests.root_module.addImport("applications", applications_module);
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
    for ([_]*std.Build.Step.Compile{ release_server, oauth_route_tests, account_route_tests, admin_route_tests }) |artifact| {
        artifact.root_module.addImport("mojang", mojang_module);
        artifact.root_module.addImport("fake_mojang", fake_mojang_module);
    }

    const game_auth_route_tests = b.addTest(.{
        .root_source_file = b.path("test/game_auth_routes_test.zig"),
        .target = target,
        .optimize = optimize,
        .filters = b.args orelse &.{},
    });
    game_auth_route_tests.root_module.addImport("db_pool", pool_module);
    game_auth_route_tests.root_module.addImport("domain", domain_module);
    game_auth_route_tests.root_module.addImport("migrations", migrations_module);
    game_auth_route_tests.root_module.addImport("postgres", postgres_module);
    game_auth_route_tests.root_module.addImport("game_auth_repository", game_auth_repository_module);
    game_auth_route_tests.root_module.addImport("game_auth_service", game_auth_service_module);
    game_auth_route_tests.root_module.addImport("applications", applications_module);
    game_auth_route_tests.root_module.addImport("game_auth_routes", game_auth_routes_module);
    game_auth_route_tests.root_module.addImport("http_server", http_server_module);
    game_auth_route_tests.root_module.addImport("config", config_module);
    game_auth_route_tests.linkLibC();
    game_auth_route_tests.linkSystemLibrary("pq");
    const integration_check = b.step("check-game-auth-integration", "Compile game-auth integration sources without running them");
    integration_check.dependOn(&game_auth_route_tests.step);
    integration_check.dependOn(&exe.step);

    const disposable_postgres = b.addSystemCommand(&.{ "python3", "test/support/game_auth_postgres.py", "--postgres-bin", b.option([]const u8, "game-auth-postgres-bin", "Directory containing already-provisioned PostgreSQL binaries") orelse "" });
    disposable_postgres.addArtifactArg(game_auth_route_tests);
    disposable_postgres.has_side_effects = true;
    b.step("test-game-auth-postgres", "Explicitly run real game-auth fixtures in a new disposable loopback PostgreSQL cluster").dependOn(&disposable_postgres.step);

    const contract_repository = b.createModule(.{
        .root_source_file = b.path("test/support/game_auth_contract_repository.zig"),
        .target = target,
        .optimize = optimize,
    });
    contract_repository.addImport("game_auth_repository", game_auth_repository_module);
    const contract_service = b.createModule(.{
        .root_source_file = b.path("src/services/game_auth.zig"),
        .target = target,
        .optimize = optimize,
    });
    contract_service.addImport("db_pool", pool_module);
    contract_service.addImport("domain", domain_module);
    contract_service.addImport("game_auth_repository", contract_repository);
    const contract_tests = b.addTest(.{
        .root_source_file = b.path("test/game_auth_offline_test.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .filters = &.{ "game_auth_contract_test", "game-auth boundary" },
    });
    contract_tests.root_module.addImport("game_auth_service", contract_service);
    contract_tests.root_module.addImport("contract_repository", contract_repository);
    contract_tests.root_module.addImport("game_auth_repository", game_auth_repository_module);
    contract_tests.linkLibC();
    const offline_step = b.step("test-game-auth", "Run only offline game-auth fixtures");
    offline_step.dependOn(&b.addRunArtifact(contract_tests).step);
    const boundary_routes = b.createModule(.{ .root_source_file = b.path("src/routes/game_auth.zig"), .target = target, .optimize = optimize });
    boundary_routes.addImport("config", config_module);
    boundary_routes.addImport("db_pool", pool_module);
    boundary_routes.addImport("game_auth_service", contract_service);
    boundary_routes.addImport("http_server", http_server_module);
    contract_tests.root_module.addImport("game_auth_routes", boundary_routes);
    contract_tests.root_module.addImport("config", config_module);
    contract_tests.root_module.addImport("http_server", http_server_module);
    const listener_tests = b.addTest(.{ .root_source_file = b.path("test/game_auth_boundary_test.zig"), .target = target, .optimize = optimize, .filters = &.{"game-auth listener"} });
    listener_tests.root_module.addImport("game_auth_routes", boundary_routes);
    listener_tests.root_module.addImport("game_auth_service", contract_service);
    listener_tests.root_module.addImport("config", config_module);
    listener_tests.root_module.addImport("http_server", http_server_module);
    listener_tests.linkLibC();
    b.step("test-game-auth-listener", "Explicitly run disposable loopback transport fixtures; no database").dependOn(&b.addRunArtifact(listener_tests).step);

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
    runtime_tests.root_module.addImport("http_server", http_server_module);
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
    test_step.dependOn(&run_mojang.step);
    test_step.dependOn(&run_response_tests.step);
    test_step.dependOn(&run_wire_tests.step);
    test_step.dependOn(&run_runtime_tests.step);
    test_step.dependOn(&run_health_route_tests.step);
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_domain_tests.step);
    test_step.dependOn(&run_migration_tests.step);
    test_step.dependOn(&run_password_tests.step);
    test_step.dependOn(&run_application_repository_tests.step);
    test_step.dependOn(&run_auth_tests.step);
    test_step.dependOn(&run_oauth_route_tests.step);
    test_step.dependOn(&run_account_route_tests.step);
    test_step.dependOn(&run_admin_route_tests.step);
    test_step.dependOn(&run_pool_tests.step);
}

fn transportRPaths(b: *std.Build, artifact: *std.Build.Step.Compile, pq: bool) void {
    // canonical directories of explicitly supplied libs only
    for ([_][]const u8{ "curl", "cares", "ssl", "crypto", "z", "pq" }) |name| {
        if (!pq and std.mem.eql(u8, name, "pq")) continue;
        for (b.search_prefixes.items) |prefix| {
            const file = b.fmt("{s}/lib/lib{s}.so", .{ prefix, name });
            const real = std.fs.cwd().realpathAlloc(b.allocator, file) catch continue;
            artifact.addRPath(.{ .cwd_relative = std.fs.path.dirname(real).? });
            break;
        }
    }
}

fn transportTests(b: *std.Build, name: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, filters: []const []const u8, domain: *std.Build.Module, mojang: *std.Build.Module, adapter: *std.Build.Module, support: *std.Build.Module, metadata: *std.Build.Module) *std.Build.Step.Compile {
    const artifact = b.addTest(.{ .name = name, .root_source_file = b.path("test/mojang_transport_test.zig"), .target = target, .optimize = optimize, .filters = filters });
    artifact.root_module.addImport("domain", domain);
    artifact.root_module.addImport("mojang", mojang);
    artifact.root_module.addImport("mojang_transport", adapter);
    artifact.root_module.addImport("mojang_transport_support", support);
    artifact.root_module.addImport("mojang_build", metadata);
    artifact.linkLibC();
    for ([_][]const u8{ "curl", "ssl", "crypto" }) |library| artifact.linkSystemLibrary2(library, .{ .use_pkg_config = .no });
    transportRPaths(b, artifact, false);
    return artifact;
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
