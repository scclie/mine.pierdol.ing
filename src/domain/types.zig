pub const ApplicationStatus = enum {
    pending,
    approved,
    rejected_retryable,
    rejected_final,
    banned,
};

pub const ClientType = enum { licensed, cracked };

pub const Role = enum { player, moderator, administrator };

pub const Actor = struct {
    user_id: i64,
    role: Role,
};

pub const Action = enum {
    view_own_account,
    create_application,
    resubmit_application,
    change_own_password,
    view_moderation_queue,
    approve_application,
    reject_application,
    view_user_card,
    edit_user_identity,
    change_user_status,
};
