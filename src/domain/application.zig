const types = @import("types.zig");
const std = @import("std");
const nickname = @import("nickname.zig");

/// self-service resubmission never changes identity, even for admins.
pub fn requireUnchangedNickname(current: []const u8, proposed: nickname.CanonicalNickname) !void {
    if (!std.mem.eql(u8, current, proposed.display())) return error.NicknameImmutable;
}

/// describes state edges, not authorization; callers enforce permissions for ban/unban edges.
pub fn canTransition(from: types.ApplicationStatus, to: types.ApplicationStatus) bool {
    if (from == to) return false;
    if (from == .banned or to == .banned) return true;

    return switch (from) {
        .pending => to == .approved or to == .rejected_retryable or to == .rejected_final,
        .rejected_retryable => to == .pending,
        .approved, .rejected_final, .banned => false,
    };
}

/// role capability only; callers enforce ownership, state, and banned read-only restrictions.
pub fn canPerform(role: types.Role, action: types.Action) bool {
    return switch (action) {
        .view_own_account, .create_application, .resubmit_application, .change_own_password => true,
        .view_moderation_queue, .approve_application, .reject_application, .view_user_card => role == .moderator or role == .administrator,
        .edit_user_identity, .change_user_status => role == .administrator,
    };
}
