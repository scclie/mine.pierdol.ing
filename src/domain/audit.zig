const std = @import("std");
const types = @import("types.zig");

pub const AuditAction = enum {
    application_created,
    application_resubmitted,
    application_approved,
    application_rejected_retryable,
    application_rejected_final,
    user_banned,
    user_unbanned,
    user_nickname_changed,
    user_discord_id_changed,
    user_client_type_changed,
    password_changed,
    licensed_mojang_uuid_changed,
};

/// shows what changed before and after, without storing account data or secrets.
pub const AuditValues = struct {
    status: ?types.ApplicationStatus = null,
    nickname: ?[]const u8 = null,
    discord_id: ?[]const u8 = null,
    client_type: ?types.ClientType = null,
    created_at: ?i64 = null,
    updated_at: ?i64 = null,
    submitted_at: ?i64 = null,
    decided_at: ?i64 = null,
    changed_at: ?i64 = null,
};

/// only allowed data is serialized, caller owns and frees the json.
pub fn serialize(allocator: std.mem.Allocator, values: AuditValues) std.mem.Allocator.Error![]u8 {
    return std.json.stringifyAlloc(allocator, values, .{ .emit_null_optional_fields = false });
}

pub const UuidSource = enum { mojang_lookup, manual_admin, cracked_clear, premium_session };

/// explicit nulls distinguish an absent binding from an omitted ordinary value.
pub fn serializeUuid(allocator: std.mem.Allocator, uuid: ?[]const u8, source: UuidSource) std.mem.Allocator.Error![]u8 {
    return std.json.stringifyAlloc(allocator, .{ .licensed_mojang_uuid = uuid, .source = source }, .{ .emit_null_optional_fields = true });
}
