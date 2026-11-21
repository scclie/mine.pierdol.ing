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
        "",       "a",    "ab",   "abcdefghijklmnopq", "a-b",
        "éab",
        " aab",   "aab ", "a.b",  "a/b",               "a\nb",
        "a\x00b", "a\tb", "a\\b",
        "соси жопу",
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
        .licensed_mojang_uuid_changed,
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
        "\"licensed_mojang_uuid_changed\"",
    };
    try std.testing.expectEqual(actions.len, @typeInfo(audit.AuditAction).Enum.fields.len);
    for (actions, expected) |action, want| {
        const json = try std.json.stringifyAlloc(std.testing.allocator, action, .{});
        defer std.testing.allocator.free(json);
        try std.testing.expectEqualStrings(want, json);
    }
}

test "licensed UUID parsers normalize spelling without imposing a version" {
    const U = domain.mojang_uuid.Uuid;
    const expected = "4af7fe6c-cb9e-4012-bef8-adf078f34694";
    const id = try U.parseProvider("4AF7FE6CCB9E4012BEF8ADF078F34694");
    try std.testing.expectEqualStrings(expected, &id.format());
    try std.testing.expect(id.eql(try U.parseProvider(expected)));
    try std.testing.expect(id.eql(try U.parseAdmin(" \t\r\n4AF7FE6C-CB9E-4012-BEF8-ADF078F34694\t ")));
    const non_v4 = try U.parseAdmin("00000000-0000-1000-0000-000000000001");
    try std.testing.expectEqualStrings("00000000-0000-1000-0000-000000000001", &non_v4.format());
    try std.testing.expect(!id.eql(non_v4));
    try expectLicensedError(error.InvalidLicensedMojangUuid, U.parseAdmin("4af7fe6ccb9e4012bef8adf078f34694"));
    for ([_][]const u8{
        "",                                     "00000000-0000-0000-0000-000000000000",    "00000000000000000000000000000000",
        "4af7fe6c-cb9e-4012-bef8-adf078f3469",  "4af7fe6c-cb9e-4012-bef8-adf078f346940",   "4af7fe6c_cb9e-4012-bef8-adf078f34694",
        "4af7fe6c-cb9e-4012-bef8-adf078f3469g", "4af7fe6c-cb9e-4012-bef8-adf078f3469\x00", "4af7fe6c-cb9e-4012-bef8-adf078f3469 ",
        "4af7fe6cc b9e4012bef8adf078f34694",    "4af7fe6ccb9e4012bef8adf078f3469g",        "4af7fe6ccb9e4012bef8adf078f3469\x00",
        "4af7fe6ccb9e4012bef8adf078f346940",
    }) |raw| {
        try expectLicensedError(error.InvalidLicensedMojangUuid, U.parseAdmin(raw));
        try expectLicensedError(error.InvalidLicensedMojangUuid, U.parseProvider(raw));
    }
    for ([_][]const u8{ " 4af7fe6c-cb9e-4012-bef8-adf078f34694", "4af7fe6c-cb9e-4012-bef8-adf078f34694\n", " 4af7fe6ccb9e4012bef8adf078f34694" }) |raw| {
        try expectLicensedError(error.InvalidLicensedMojangUuid, U.parseProvider(raw));
    }
}

fn licensedSnapshot(client: types.ClientType, status: types.ApplicationStatus) !domain.licensed_admission.Snapshot {
    return .{ .revision = 1, .identity_id = 7, .uuid = try domain.mojang_uuid.Uuid.parseProvider("4af7fe6ccb9e4012bef8adf078f34694"), .application = .{
        .nickname = try nickname.validateNickname("Example_Name"),
        .client_type = client,
        .status = status,
    } };
}

// use Uuid.format as the domain api, avoid formatting uuid payloads in expectError diagnostics
fn expectLicensedError(expected: anyerror, actual: anytype) !void {
    _ = actual catch |err| {
        try std.testing.expectEqual(expected, err);
        return;
    };
    return error.TestExpectedError;
}

test "licensed policy writer table requires lookup only for licensed admission edges" {
    const a = domain.licensed_admission;
    const n = try nickname.validateNickname("Example_Name");
    const cases = [_]struct { current: ?a.Snapshot, intent: a.Intent, lookup: bool, clear: bool = false }{
        .{ .current = null, .intent = .{ .operation = .create, .nickname = n, .client_type = .licensed }, .lookup = true },
        .{ .current = null, .intent = .{ .operation = .create, .nickname = n, .client_type = .cracked }, .lookup = false, .clear = true },
        .{ .current = try licensedSnapshot(.licensed, .rejected_retryable), .intent = .{ .operation = .resubmit }, .lookup = true },
        .{ .current = try licensedSnapshot(.licensed, .rejected_retryable), .intent = .{ .operation = .resubmit, .client_type = .licensed }, .lookup = true },
        .{ .current = try licensedSnapshot(.cracked, .rejected_retryable), .intent = .{ .operation = .resubmit, .client_type = .licensed }, .lookup = true },
        .{ .current = try licensedSnapshot(.licensed, .rejected_retryable), .intent = .{ .operation = .resubmit, .client_type = .cracked }, .lookup = false, .clear = true },
        .{ .current = try licensedSnapshot(.cracked, .rejected_retryable), .intent = .{ .operation = .resubmit }, .lookup = false, .clear = true },
        .{ .current = try licensedSnapshot(.licensed, .pending), .intent = .{ .operation = .approve, .status = .approved }, .lookup = true },
        .{ .current = try licensedSnapshot(.cracked, .pending), .intent = .{ .operation = .approve, .status = .approved }, .lookup = false, .clear = true },
        .{ .current = try licensedSnapshot(.licensed, .pending), .intent = .{ .operation = .reject, .status = .rejected_retryable }, .lookup = false },
        .{ .current = try licensedSnapshot(.licensed, .pending), .intent = .{ .operation = .reject, .status = .rejected_final }, .lookup = false },
        .{ .current = try licensedSnapshot(.licensed, .approved), .intent = .{ .operation = .edit }, .lookup = false },
        .{ .current = try licensedSnapshot(.licensed, .approved), .intent = .{ .operation = .edit, .nickname = n, .client_type = .licensed }, .lookup = false },
        .{ .current = try licensedSnapshot(.licensed, .approved), .intent = .{ .operation = .edit, .nickname = try nickname.validateNickname("example_name") }, .lookup = true },
        .{ .current = try licensedSnapshot(.licensed, .approved), .intent = .{ .operation = .edit, .nickname = try nickname.validateNickname("Other_Name") }, .lookup = true },
        .{ .current = try licensedSnapshot(.cracked, .approved), .intent = .{ .operation = .edit, .client_type = .licensed }, .lookup = true },
        .{ .current = try licensedSnapshot(.licensed, .approved), .intent = .{ .operation = .edit, .client_type = .cracked }, .lookup = false, .clear = true },
        .{ .current = try licensedSnapshot(.licensed, .approved), .intent = .{ .operation = .edit, .status = .banned }, .lookup = false },
        .{ .current = try licensedSnapshot(.licensed, .banned), .intent = .{ .operation = .edit, .status = .approved }, .lookup = true },
        .{ .current = try licensedSnapshot(.licensed, .banned), .intent = .{ .operation = .edit, .status = .pending }, .lookup = false },
    };
    for (cases) |case| {
        const d = try a.evaluate(case.current, case.intent);
        try std.testing.expectEqual(case.lookup, d.lookup_required);
        try std.testing.expectEqual(case.clear, d.clear);
        if (case.intent.operation == .create or case.intent.operation == .resubmit) try std.testing.expectEqual(types.ApplicationStatus.pending, d.final.status);
    }
    var unresolved = try licensedSnapshot(.licensed, .approved);
    unresolved.uuid = null;
    try std.testing.expect((try a.evaluate(unresolved, .{ .operation = .resolve })).lookup_required);
}

test "licensed policy rejects invalid edges missing identity and unsafe manual intents" {
    const a = domain.licensed_admission;
    const licensed = try licensedSnapshot(.licensed, .pending);
    const cracked = try licensedSnapshot(.cracked, .pending);
    const id = licensed.uuid.?;
    try expectLicensedError(error.InvalidLicensedMojangUuid, a.evaluate(licensed, .{ .operation = .edit, .uuid = .clear }));
    try expectLicensedError(error.InvalidLicensedMojangUuid, a.evaluate(cracked, .{ .operation = .edit, .uuid = .{ .set = id }, .confirmed_override = true, .has_reason = true }));
    for ([_]a.Intent{
        .{ .operation = .edit, .uuid = .{ .set = id } },
        .{ .operation = .edit, .uuid = .{ .set = id }, .confirmed_override = true },
        .{ .operation = .edit, .uuid = .{ .set = id }, .has_reason = true },
    }) |intent| try expectLicensedError(error.ManualOverrideRequired, a.evaluate(licensed, intent));
    const manual = try a.evaluate(licensed, .{ .operation = .edit, .uuid = .{ .set = id }, .confirmed_override = true, .has_reason = true });
    try std.testing.expect(manual.manual.?.eql(id));
    try std.testing.expect(!manual.lookup_required);
    var missing = licensed;
    missing.identity_id = null;
    for ([_]a.Operation{ .resubmit, .edit, .approve, .reject, .resolve }) |operation| {
        try expectLicensedError(error.GameIdentityRequired, a.evaluate(missing, .{ .operation = operation }));
        try expectLicensedError(error.ApplicationRequired, a.evaluate(null, .{ .operation = operation }));
    }
    missing = licensed;
    missing.application = null;
    try expectLicensedError(error.ApplicationRequired, a.evaluate(missing, .{ .operation = .edit }));
    try expectLicensedError(error.InvalidTransition, a.evaluate(try licensedSnapshot(.licensed, .approved), .{ .operation = .approve, .status = .approved }));
    try expectLicensedError(error.InvalidTransition, a.evaluate(licensed, .{ .operation = .resubmit }));
    try expectLicensedError(error.InvalidTransition, a.evaluate(try licensedSnapshot(.licensed, .rejected_final), .{ .operation = .edit, .status = .approved }));
    try expectLicensedError(error.InvalidTransition, a.evaluate(licensed, .{ .operation = .reject, .status = .approved }));
    try expectLicensedError(error.InvalidTransition, a.evaluate(licensed, .{ .operation = .create }));
    try expectLicensedError(error.InvalidTransition, a.evaluate(licensed, .{ .operation = .resolve }));
    var unresolved_cracked = cracked;
    unresolved_cracked.uuid = null;
    try expectLicensedError(error.InvalidTransition, a.evaluate(unresolved_cracked, .{ .operation = .resolve }));
    try expectLicensedError(error.NicknameImmutable, a.evaluate(try licensedSnapshot(.licensed, .rejected_retryable), .{ .operation = .resubmit, .nickname = try nickname.validateNickname("example_name") }));
}

test "licensed binding validates names protects old binding and allows only explicit manual replacement" {
    const a = domain.licensed_admission;
    const U = domain.mojang_uuid.Uuid;
    const state = try licensedSnapshot(.licensed, .pending);
    const id = state.uuid.?;
    const other = try U.parseAdmin("00000000-0000-1000-0000-000000000001");
    const n = state.application.?.nickname;
    var observation = a.Observation{ .requested = n, .returned = try nickname.validateNickname("example_name"), .uuid = id, .observed_ns = 0 };
    const decision = try a.evaluate(state, .{ .operation = .approve });
    try expectLicensedError(error.MojangObservationRequired, a.binding(state, decision, null));
    try std.testing.expect((try a.binding(state, decision, observation)).?.eql(id));
    observation.uuid = other;
    try expectLicensedError(error.LicensedMojangUuidMismatch, a.binding(state, decision, observation));
    const manual = try a.evaluate(state, .{ .operation = .approve, .uuid = .{ .set = other }, .confirmed_override = true, .has_reason = true });
    try std.testing.expect((try a.binding(state, manual, observation)).?.eql(other));
    observation.uuid = id;
    try expectLicensedError(error.LicensedMojangUuidMismatch, a.binding(state, manual, observation));
    observation.returned = try nickname.validateNickname("Other_Name");
    try expectLicensedError(error.IdentityChanged, a.binding(state, decision, observation));
    observation.requested = observation.returned;
    try expectLicensedError(error.IdentityChanged, a.binding(state, decision, observation));
    observation.requested = try nickname.validateNickname("example_name");
    observation.returned = observation.requested;
    try expectLicensedError(error.IdentityChanged, a.binding(state, decision, observation));
    const rejection = try a.evaluate(state, .{ .operation = .reject, .status = .rejected_final });
    try std.testing.expect((try a.binding(state, rejection, null)).?.eql(id));
    const ban = try a.evaluate(state, .{ .operation = .edit, .status = .banned });
    try std.testing.expect((try a.binding(state, ban, null)).?.eql(id));
    try expectLicensedError(error.IdentityChanged, a.binding(state, rejection, .{ .requested = n, .returned = try nickname.validateNickname("Other_Name"), .uuid = id, .observed_ns = 0 }));
    var unbound = state;
    unbound.uuid = null;
    observation = .{ .requested = n, .returned = n, .uuid = id, .observed_ns = 0 };
    try std.testing.expect((try a.binding(unbound, decision, observation)).?.eql(id));
    const cleared = try a.evaluate(state, .{ .operation = .edit, .client_type = .cracked });
    try std.testing.expect((try a.binding(state, cleared, null)) == null);
    const reaffirmed = try a.evaluate(state, .{ .operation = .edit, .uuid = .{ .set = id }, .confirmed_override = true, .has_reason = true });
    try std.testing.expect((try a.binding(state, reaffirmed, null)).?.eql(id));
    try std.testing.expect(reaffirmed.manual != null);
    const prepared = a.Prepared{ .expected = state, .intent = .{ .operation = .approve }, .observation = observation };
    try std.testing.expectEqual(@as(u64, 1), prepared.expected.?.revision);
    const legacy = a.Prepared{ .expected = null, .intent = .{ .operation = .create }, .observation = null };
    try std.testing.expect(legacy.expected == null);
}

fn serializeLicensedUuidAllocationTest(allocator: std.mem.Allocator) !void {
    const json = try audit.serializeUuid(allocator, null, .manual_admin);
    defer allocator.free(json);
}

test "licensed UUID audit emits exact null and canonical projections without payload fields" {
    const canonical = "4af7fe6c-cb9e-4012-bef8-adf078f34694";
    for ([_]struct { uuid: ?[]const u8, source: audit.UuidSource, expected: []const u8 }{
        .{ .uuid = null, .source = .mojang_lookup, .expected = "{\"licensed_mojang_uuid\":null,\"source\":\"mojang_lookup\"}" },
        .{ .uuid = canonical, .source = .mojang_lookup, .expected = "{\"licensed_mojang_uuid\":\"4af7fe6c-cb9e-4012-bef8-adf078f34694\",\"source\":\"mojang_lookup\"}" },
        .{ .uuid = canonical, .source = .cracked_clear, .expected = "{\"licensed_mojang_uuid\":\"4af7fe6c-cb9e-4012-bef8-adf078f34694\",\"source\":\"cracked_clear\"}" },
        .{ .uuid = null, .source = .cracked_clear, .expected = "{\"licensed_mojang_uuid\":null,\"source\":\"cracked_clear\"}" },
        .{ .uuid = canonical, .source = .manual_admin, .expected = "{\"licensed_mojang_uuid\":\"4af7fe6c-cb9e-4012-bef8-adf078f34694\",\"source\":\"manual_admin\"}" },
        .{ .uuid = canonical, .source = .premium_session, .expected = "{\"licensed_mojang_uuid\":\"4af7fe6c-cb9e-4012-bef8-adf078f34694\",\"source\":\"premium_session\"}" },
    }) |case| {
        const json = try audit.serializeUuid(std.testing.allocator, case.uuid, case.source);
        defer std.testing.allocator.free(json);
        try std.testing.expectEqualStrings(case.expected, json);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 2), parsed.value.object.count());
    }
    try std.testing.checkAllAllocationFailures(std.testing.allocator, serializeLicensedUuidAllocationTest, .{});
}
