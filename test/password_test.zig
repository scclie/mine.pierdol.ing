const std = @import("std");
const domain = @import("domain");
const password = domain.password;
const applications = @import("applications");
const migrations = @import("migrations");
const postgres = @import("support/postgres.zig");

fn denyList() !password.DenyList {
    return password.loadDefaultDenyList(std.testing.allocator);
}

test "password_test policy rejects short and locally denied passwords" {
    var list = try denyList();
    defer list.deinit();

    try std.testing.expectError(error.PasswordTooShort, password.validatePassword("short", list));
    try std.testing.expectError(error.PasswordDenied, password.validatePassword("correcthorsebatterystaple", list));
    try password.validatePassword("blue-harbor-falcon-2026", list);
}

test "password_test deny-list initialization frees entries when hash-map insertion runs out of memory" {
    const Context = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var list = try password.DenyList.init(allocator, "first-entry\nsecond-entry\n");
            defer list.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Context.run, .{});
}

test "password_test Argon2id hash verifies only its original password and uses a unique salt" {
    const first = try password.hashPassword(std.testing.allocator, "blue-harbor-falcon-2026");
    defer std.testing.allocator.free(first);
    const second = try password.hashPassword(std.testing.allocator, "blue-harbor-falcon-2026");
    defer std.testing.allocator.free(second);

    try std.testing.expect(std.mem.startsWith(u8, first, "$argon2id$v=19$"));
    try std.testing.expect(!std.mem.eql(u8, first, second));
    try std.testing.expect(try password.verifyPassword(first, "blue-harbor-falcon-2026"));
    try std.testing.expect(!try password.verifyPassword(first, "blue-harbor-falcon-2027"));
}

test "password_test cracked applications persist only a hash with a creation audit record" {
    const admin_database_url = std.posix.getenv("TEST_DATABASE_URL") orelse return error.TestDatabaseUrlNotConfigured;
    var test_database = try postgres.TestDatabase.create(std.testing.allocator, admin_database_url);
    defer test_database.deinit();
    try migrations.apply(&test_database.pool);

    const submitted_password = "blue-harbor-falcon-2026";
    const hash = try password.hashPassword(std.testing.allocator, submitted_password);
    defer std.testing.allocator.free(hash);
    const nickname = try domain.nickname.validateNickname("CrackedUser");
    var repository = applications.ApplicationRepository.init(&test_database.pool);
    const application = try repository.create(.{
        .discord_id = "discord-cracked-1",
        .discord_username = "cracked_user",
        .nickname = nickname,
        .client_type = .cracked,
        .about_me = "I would like to join.",
        .discovery_source = "friend",
        .password_hash = hash,
    });

    var id_buffer: [20]u8 = undefined;
    const user_id = try std.fmt.bufPrint(&id_buffer, "{d}", .{application.user_id});
    var credential_result = try test_database.pool.query(
        "SELECT password_hash FROM password_credentials WHERE user_id = $1",
        &.{user_id},
    );
    defer credential_result.deinit();
    try std.testing.expect(!std.mem.eql(u8, credential_result.value(0, 0), submitted_password));
    try std.testing.expect(try password.verifyPassword(credential_result.value(0, 0), submitted_password));

    var audit_result = try test_database.pool.query(
        "SELECT old_value IS NULL, new_value IS NULL FROM audit_log WHERE subject_user_id = $1 AND action = 'application_created'",
        &.{user_id},
    );
    defer audit_result.deinit();
    try std.testing.expectEqualStrings("t", audit_result.value(0, 0));
    try std.testing.expectEqualStrings("t", audit_result.value(0, 1));
}

test "password_test licensed applications have no credential row and reject a supplied hash" {
    const admin_database_url = std.posix.getenv("TEST_DATABASE_URL") orelse return error.TestDatabaseUrlNotConfigured;
    var test_database = try postgres.TestDatabase.create(std.testing.allocator, admin_database_url);
    defer test_database.deinit();
    try migrations.apply(&test_database.pool);

    const nickname = try domain.nickname.validateNickname("LicensedUser");
    var repository = applications.ApplicationRepository.init(&test_database.pool);
    const application = try repository.create(.{
        .discord_id = "discord-licensed-1",
        .discord_username = "licensed_user",
        .nickname = nickname,
        .client_type = .licensed,
        .about_me = "I own the game.",
        .discovery_source = "friend",
        .password_hash = null,
    });

    var id_buffer: [20]u8 = undefined;
    const user_id = try std.fmt.bufPrint(&id_buffer, "{d}", .{application.user_id});
    var credential_result = try test_database.pool.query(
        "SELECT EXISTS(SELECT 1 FROM password_credentials WHERE user_id = $1)",
        &.{user_id},
    );
    defer credential_result.deinit();
    try std.testing.expectEqualStrings("f", credential_result.value(0, 0));

    const rejected_nickname = try domain.nickname.validateNickname("NoHashUser");
    try std.testing.expectError(error.PasswordNotAllowed, repository.create(.{
        .discord_id = "discord-licensed-2",
        .discord_username = "no_hash_user",
        .nickname = rejected_nickname,
        .client_type = .licensed,
        .about_me = "I own the game too.",
        .discovery_source = "friend",
        .password_hash = "$argon2id$not-a-real-hash",
    }));
}

test "password_test failed application creation rolls back user application credential and audit records" {
    const admin_database_url = std.posix.getenv("TEST_DATABASE_URL") orelse return error.TestDatabaseUrlNotConfigured;
    var test_database = try postgres.TestDatabase.create(std.testing.allocator, admin_database_url);
    defer test_database.deinit();
    try migrations.apply(&test_database.pool);

    var repository = applications.ApplicationRepository.init(&test_database.pool);
    const existing_nickname = try domain.nickname.validateNickname("TakenNickname");
    _ = try repository.create(.{
        .discord_id = "discord-existing-1",
        .discord_username = "existing_user",
        .nickname = existing_nickname,
        .client_type = .licensed,
        .about_me = "Existing application.",
        .discovery_source = "friend",
        .password_hash = null,
    });

    try std.testing.expectError(error.QueryFailed, repository.create(.{
        .discord_id = "discord-rolled-back-1",
        .discord_username = "rolled_back_user",
        .nickname = existing_nickname,
        .client_type = .licensed,
        .about_me = "This application conflicts.",
        .discovery_source = "friend",
        .password_hash = null,
    }));

    const failed_discord_id = "discord-rolled-back-1";
    const remaining_records = [_][]const u8{
        "SELECT count(*) FROM users WHERE discord_id = $1",
        "SELECT count(*) FROM applications JOIN users ON users.id = applications.user_id WHERE users.discord_id = $1",
        "SELECT count(*) FROM password_credentials JOIN users ON users.id = password_credentials.user_id WHERE users.discord_id = $1",
        "SELECT count(*) FROM audit_log JOIN users ON users.id = audit_log.subject_user_id WHERE users.discord_id = $1",
    };
    for (remaining_records) |sql| {
        var result = try test_database.pool.query(sql, &.{failed_discord_id});
        defer result.deinit();
        try std.testing.expectEqualStrings("0", result.value(0, 0));
    }
}

test "password_test replacement affects only approved cracked applications and stores a verifying replacement hash" {
    const admin_database_url = std.posix.getenv("TEST_DATABASE_URL") orelse return error.TestDatabaseUrlNotConfigured;
    var test_database = try postgres.TestDatabase.create(std.testing.allocator, admin_database_url);
    defer test_database.deinit();
    try migrations.apply(&test_database.pool);

    const initial_hash = try password.hashPassword(std.testing.allocator, "blue-harbor-falcon-2026");
    defer std.testing.allocator.free(initial_hash);
    const replacement_hash = try password.hashPassword(std.testing.allocator, "blue-harbor-falcon-2027");
    defer std.testing.allocator.free(replacement_hash);
    const nickname = try domain.nickname.validateNickname("ApprovedUser");
    var repository = applications.ApplicationRepository.init(&test_database.pool);
    const application = try repository.create(.{
        .discord_id = "discord-approved-1",
        .discord_username = "approved_user",
        .nickname = nickname,
        .client_type = .cracked,
        .about_me = "I would like to join.",
        .discovery_source = "friend",
        .password_hash = initial_hash,
    });

    const licensed_nickname = try domain.nickname.validateNickname("ApprovedLicense");
    const licensed_application = try repository.create(.{
        .discord_id = "discord-approved-license-1",
        .discord_username = "approved_license",
        .nickname = licensed_nickname,
        .client_type = .licensed,
        .about_me = "I own the game.",
        .discovery_source = "friend",
        .password_hash = null,
    });

    try std.testing.expectError(error.PasswordChangeNotAllowed, repository.replacePassword(application.user_id, replacement_hash));
    var licensed_id_buffer: [20]u8 = undefined;
    const licensed_user_id = try std.fmt.bufPrint(&licensed_id_buffer, "{d}", .{licensed_application.user_id});
    var approve_licensed_result = try test_database.pool.query(
        "UPDATE applications SET status = 'approved' WHERE user_id = $1",
        &.{licensed_user_id},
    );
    approve_licensed_result.deinit();
    try std.testing.expectError(error.PasswordChangeNotAllowed, repository.replacePassword(licensed_application.user_id, replacement_hash));

    var id_buffer: [20]u8 = undefined;
    const user_id = try std.fmt.bufPrint(&id_buffer, "{d}", .{application.user_id});
    var approve_result = try test_database.pool.query(
        "UPDATE applications SET status = 'approved' WHERE user_id = $1",
        &.{user_id},
    );
    approve_result.deinit();

    try repository.replacePassword(application.user_id, replacement_hash);
    var credential_result = try test_database.pool.query(
        "SELECT password_hash FROM password_credentials WHERE user_id = $1",
        &.{user_id},
    );
    defer credential_result.deinit();
    try std.testing.expect(try password.verifyPassword(credential_result.value(0, 0), "blue-harbor-falcon-2027"));
    try std.testing.expect(!try password.verifyPassword(credential_result.value(0, 0), "blue-harbor-falcon-2026"));

    var audit_result = try test_database.pool.query(
        "SELECT old_value IS NULL, new_value IS NULL FROM audit_log WHERE subject_user_id = $1 AND action = 'password_changed'",
        &.{user_id},
    );
    defer audit_result.deinit();
    try std.testing.expectEqualStrings("t", audit_result.value(0, 0));
    try std.testing.expectEqualStrings("t", audit_result.value(0, 1));
}
