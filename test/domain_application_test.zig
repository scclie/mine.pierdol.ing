const std = @import("std");
const domain = @import("domain");
const types = domain.types;
const application = domain.application;
const nickname = domain.nickname;
const audit = domain.audit;

test "domain_application_test state transitions allow only decisions, resubmission, and ban changes" {
    const statuses = [_]types.ApplicationStatus{
        .pending, .approved, .rejected_retryable, .rejected_final, .banned,
    };
    const allowed = [_][5]bool{
        .{ false, true, true, true, true },
        .{ false, false, false, false, true },
        .{ true, false, false, false, true },
        .{ false, false, false, false, true },
        .{ true, true, true, true, false },
    };
    for (statuses, 0..) |from, row| {
        for (statuses, 0..) |to, column| {
            try std.testing.expectEqual(allowed[row][column], application.canTransition(from, to));
        }
    }
}

test "domain_application_test role permissions reserve identity and status overrides for administrators" {
    const actors = [_]types.Actor{
        .{ .user_id = 1, .role = .player },
        .{ .user_id = 2, .role = .moderator },
        .{ .user_id = 3, .role = .administrator },
    };
    const actions = [_]types.Action{
        .view_own_account,    .create_application,    .resubmit_application,
        .change_own_password, .view_moderation_queue, .approve_application,
        .reject_application,  .view_user_card,        .edit_user_identity,
        .change_user_status,
    };
    const allowed = [_][10]bool{
        .{ true, true, true, true, false, false, false, false, false, false },
        .{ true, true, true, true, true, true, true, true, false, false },
        .{ true, true, true, true, true, true, true, true, true, true },
    };
    for (actors, 0..) |actor, row| {
        for (actions, 0..) |action, column| {
            try std.testing.expectEqual(allowed[row][column], application.canPerform(actor.role, action));
        }
    }
}

test "domain_application_test nicknames preserve display case but share a lowercase lookup value" {
    const examples = [_]struct { raw: []const u8, canonical: []const u8 }{
        .{ .raw = "Example_Name", .canonical = "example_name" },
        .{ .raw = "example_name", .canonical = "example_name" },
        .{ .raw = "A_0", .canonical = "a_0" },
        .{ .raw = "ABCDEF0123456789", .canonical = "abcdef0123456789" },
        .{ .raw = "___", .canonical = "___" },
    };
    for (examples) |example| {
        const validated = try nickname.validateNickname(example.raw);
        try std.testing.expectEqualStrings(example.raw, validated.display());
        try std.testing.expectEqualStrings(example.canonical, validated.canonical());
    }
}

test "domain_application_test retry submissions preserve exact display nickname including case" {
    const original = try nickname.validateNickname("Example_Name");
    try application.requireUnchangedNickname("Example_Name", original);
    for ([_][]const u8{ "example_name", "Other_Name" }) |value| {
        try std.testing.expectError(error.NicknameImmutable, application.requireUnchangedNickname("Example_Name", try nickname.validateNickname(value)));
    }
}

test "domain_application_test nicknames reject invalid length and non Minecraft characters" {
    const invalid = [_][]const u8{
        "",       "a",      "ab",   "abcdefghijklmnopq", "a-b",
        "éab",   " aab",   "aab ", "a.b",               "a/b",
        "a\nb",   "a\x00b", "a\tb", "a\\b",              "соси жопу",
        "a\xffb",
    };
    for (invalid) |raw| {
        try std.testing.expectError(error.InvalidNickname, nickname.validateNickname(raw));
    }
}

test "domain_application_test nickname validation checks every byte against the ASCII allowlist" {
    const allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_";
    var raw = [_]u8{ 'a', 0, 'b' };
    for (0..256) |byte| {
        raw[1] = @intCast(byte);
        if (std.mem.indexOfScalar(u8, allowed, raw[1]) != null) {
            const validated = try nickname.validateNickname(&raw);
            try std.testing.expectEqualStrings(&raw, validated.display());
        } else {
            try std.testing.expectError(error.InvalidNickname, nickname.validateNickname(&raw));
        }
    }
}

test "domain_application_test validated nicknames own their display and canonical storage" {
    var raw = "Example_Name".*;
    var original = try nickname.validateNickname(&raw);
    const copied = original;
    @memset(&raw, 'x');
    original = try nickname.validateNickname("Other_Name");
    try std.testing.expectEqualStrings("Other_Name", original.display());
    try std.testing.expectEqualStrings("Example_Name", copied.display());
    try std.testing.expectEqualStrings("example_name", copied.canonical());
}

test "domain_application_test audit serialization contains only approved values" {
    const json = try audit.serialize(std.testing.allocator, .{
        .status = .approved,
        .nickname = "Example_Name",
        .discord_id = "123456789012345678",
        .client_type = .licensed,
        .created_at = 100,
        .updated_at = 200,
        .submitted_at = 150,
        .decided_at = 200,
        .changed_at = 200,
    });
    defer std.testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqual(@as(usize, 9), object.count());
    try std.testing.expectEqualStrings("approved", object.get("status").?.string);
    try std.testing.expectEqualStrings("Example_Name", object.get("nickname").?.string);
    try std.testing.expectEqualStrings("123456789012345678", object.get("discord_id").?.string);
    try std.testing.expectEqualStrings("licensed", object.get("client_type").?.string);
    try std.testing.expectEqual(@as(i64, 100), object.get("created_at").?.integer);
    try std.testing.expectEqual(@as(i64, 200), object.get("updated_at").?.integer);
    try std.testing.expectEqual(@as(i64, 150), object.get("submitted_at").?.integer);
    try std.testing.expectEqual(@as(i64, 200), object.get("decided_at").?.integer);
    try std.testing.expectEqual(@as(i64, 200), object.get("changed_at").?.integer);
}

test "domain_application_test audit serialization omits absent values and escapes JSON strings" {
    const empty = try audit.serialize(std.testing.allocator, .{});
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqualStrings("{}", empty);

    const json = try audit.serialize(std.testing.allocator, .{
        .discord_id = "quote\"backslash\\newline\n",
        .client_type = .cracked,
    });
    defer std.testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.object.count());
    try std.testing.expectEqualStrings("quote\"backslash\\newline\n", parsed.value.object.get("discord_id").?.string);
    try std.testing.expectEqualStrings("cracked", parsed.value.object.get("client_type").?.string);
}

test "domain_application_test audit status snapshots serialize every state" {
    const statuses = [_]types.ApplicationStatus{
        .pending, .approved, .rejected_retryable, .rejected_final, .banned,
    };
    const expected = [_][]const u8{
        "{\"status\":\"pending\"}",
        "{\"status\":\"approved\"}",
        "{\"status\":\"rejected_retryable\"}",
        "{\"status\":\"rejected_final\"}",
        "{\"status\":\"banned\"}",
    };
    for (statuses, expected) |status, want| {
        const json = try audit.serialize(std.testing.allocator, .{ .status = status });
        defer std.testing.allocator.free(json);
        try std.testing.expectEqualStrings(want, json);
    }
}

fn serializeAuditForAllocationTest(allocator: std.mem.Allocator) !void {
    const json = try audit.serialize(allocator, .{
        .status = .approved,
        .nickname = "Example_Name",
        .discord_id = "123456789012345678",
        .client_type = .cracked,
        .changed_at = 200,
    });
    defer allocator.free(json);
}

test "domain_application_test audit serialization propagates allocation failure without leaking" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, serializeAuditForAllocationTest, .{});
}

test "domain_application_test audit boundary accepts a concrete secret free projection" {
    const parameters = @typeInfo(@TypeOf(audit.serialize)).Fn.params;
    try std.testing.expect(parameters[1].type.? == audit.AuditValues);
    const allowed = [_][]const u8{
        "status",     "nickname",     "discord_id", "client_type", "created_at",
        "updated_at", "submitted_at", "decided_at", "changed_at",
    };
    inline for (@typeInfo(audit.AuditValues).Struct.fields) |field| {
        var found = false;
        for (allowed) |name| {
            if (std.mem.eql(u8, field.name, name)) found = true;
        }
        try std.testing.expect(found);
    }
}

test "domain_application_test audit actions serialize as the closed event vocabulary" {
    const actions = [_]audit.AuditAction{
        .application_created,
        .application_resubmitted,
        .application_approved,
        .application_rejected_retryable,
        .application_rejected_final,
        .user_banned,
        .user_unbanned,
        .user_nickname_changed,
        .user_discord_id_changed,
        .user_client_type_changed,
        .password_changed,
    };
    const expected = [_][]const u8{
        "\"application_created\"",
        "\"application_resubmitted\"",
        "\"application_approved\"",
        "\"application_rejected_retryable\"",
        "\"application_rejected_final\"",
        "\"user_banned\"",
        "\"user_unbanned\"",
        "\"user_nickname_changed\"",
        "\"user_discord_id_changed\"",
        "\"user_client_type_changed\"",
        "\"password_changed\"",
    };
    try std.testing.expectEqual(actions.len, @typeInfo(audit.AuditAction).Enum.fields.len);
    for (actions, expected) |action, want| {
        const json = try std.json.stringifyAlloc(std.testing.allocator, action, .{});
        defer std.testing.allocator.free(json);
        try std.testing.expectEqualStrings(want, json);
    }
}
