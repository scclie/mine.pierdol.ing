const types = @import("types.zig");

/// describes state edges, not authorization. administrator-only change_user_status permission at the call site for ban/unban edges additionally need the
pub fn canTransition(from: types.ApplicationStatus, to: types.ApplicationStatus) bool {
    if (from == to) return false;
    if (from == .banned or to == .banned) return true;

    return switch (from) {
        .pending => to == .approved or to == .rejected_retryable or to == .rejected_final,
        .rejected_retryable => to == .pending,
        .approved, .rejected_final, .banned => false,
    };
}

/// role capability only enforced by callers, ownership and state restrictions - banned accounts' read-only access.
pub fn canPerform(role: types.Role, action: types.Action) bool {
    return switch (action) {
        .view_own_account, .create_application, .resubmit_application, .change_own_password => true,
        .view_moderation_queue, .approve_application, .reject_application, .view_user_card => role == .moderator or role == .administrator,
        .edit_user_identity, .change_user_status => role == .administrator,
    };
}
