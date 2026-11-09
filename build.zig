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
    const migrations_module = b.createModule(.{
        .root_source_file = b.path("src/db/migrations.zig"),
        .target = target,
        .optimize = optimize,
    });
    migrations_module.addImport("db_pool", pool_module);
    migrations_module.addImport("migration_files", migration_files_module);

    const exe = b.addExecutable(.{
        .name = "mine-api",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("db_pool", pool_module);
    exe.root_module.addImport("migration_files", migration_files_module);
    exe.linkLibC();
    exe.linkSystemLibrary("pq");
    b.installArtifact(exe);

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .filters = b.args orelse &.{},
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

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

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_migration_tests.step);
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

fn lessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}
