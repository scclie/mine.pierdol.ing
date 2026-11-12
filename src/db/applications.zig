const std = @import("std");
const db = @import("db_pool");
const domain = @import("domain");
const auth = @import("auth");
const users = @import("users");

const nickname = domain.nickname;
const types = domain.types;

fn writeAudit(transaction: *db.Transaction, allocator: std.mem.Allocator, actor: []const u8, subject: []const u8, action: domain.audit.AuditAction, old: domain.audit.AuditValues, new: domain.audit.AuditValues, reason: ?[]const u8) !void {
    const before = try domain.audit.serialize(allocator, old);
    defer allocator.free(before);
    const after = try domain.audit.serialize(allocator, new);
    defer allocator.free(after);
    var result = try transaction.query("INSERT INTO audit_log (actor_user_id,subject_user_id,action,old_value,new_value,reason) VALUES ($1,$2,$3,$4::jsonb,$5::jsonb,$6)", &.{ actor, subject, @tagName(action), before, after, reason });
    result.deinit();
}

pub const Application = struct {
    user_id: i64,
    nickname: nickname.CanonicalNickname,
    client_type: types.ClientType,
    status: types.ApplicationStatus = .pending,
};

pub const CreateInput = struct {
    discord_id: []const u8,
    discord_username: []const u8,
    discord_global_name: ?[]const u8 = null,
    discord_avatar_hash: ?[]const u8 = null,
    nickname: nickname.CanonicalNickname,
    client_type: types.ClientType,
    about_me: []const u8,
    discovery_source: []const u8,
    password_hash: ?[]const u8,
};

pub const AccountInput = struct {
    nickname: nickname.CanonicalNickname,
    client_type: types.ClientType,
    about_me: []const u8,
    discovery_source: []const u8,
    password_hash: ?[]const u8,
};

pub const Mutation = enum { create, resubmit, password };

pub const SessionProof = struct {
    token_hash: [66]u8,
    csrf_hash: [66]u8,
    next_csrf_hash: [66]u8,
};

pub const Queue = struct {
    status: types.ApplicationStatus = .pending,
    query: ?[]const u8 = null,
    limit: u8 = 25,
    cursor_time: ?i64 = null,
    cursor_id: ?i64 = null,
};

pub const AdminPatch = struct {
    nickname: ?nickname.CanonicalNickname = null,
    discord_id: ?[]const u8 = null,
    client_type: ?types.ClientType = null,
    status: ?types.ApplicationStatus = null,
    reason: ?[]const u8 = null,
};

pub const AdminMutation = enum { approve, reject, edit };

pub fn requireAction(actor: types.Actor, mutation: Mutation, status: ?types.ApplicationStatus, client_type: ?types.ClientType) !void {
    const action: types.Action = switch (mutation) {
        .create => .create_application,
        .resubmit => .resubmit_application,
        .password => .change_own_password,
    };
    if (!domain.application.canPerform(actor.role, action)) return error.AccountReadOnly;
    if (status == .banned or status == .rejected_final) return error.AccountReadOnly;
    switch (mutation) {
        .create => if (status != null) return error.ApplicationAlreadyExists,
        .resubmit => if (status != .rejected_retryable) return error.ApplicationNotEditable,
        .password => {
            if (client_type != .cracked) return error.PasswordNotApplicable;
            if (status != .approved) return error.PasswordChangeNotAllowed;
        },
    }
}

pub const ApplicationRepository = struct {
    pool: *db.Pool,

    pub fn init(pool: *db.Pool) ApplicationRepository {
        return .{ .pool = pool };
    }

    /// only expose public account data.
    pub fn account(self: *ApplicationRepository, user_id: i64) !db.Result {
        var buffer: [20]u8 = undefined;
        const id = try std.fmt.bufPrint(&buffer, "{d}", .{user_id});
        return self.pool.query(
            "SELECT users.id, users.discord_id, COALESCE(users.discord_global_name, users.discord_username), applications.minecraft_nickname, applications.client_type, applications.status, applications.decision_reason, applications.decision_reason IS NULL, NOT EXISTS (SELECT 1 FROM password_credentials WHERE user_id = users.id) FROM users LEFT JOIN applications ON applications.user_id = users.id WHERE users.id = $1",
            &.{id},
        );
    }

    pub fn refreshCsrf(self: *ApplicationRepository, user_id: i64, token_hash: []const u8, csrf_hash: []const u8) !void {
        var buffer: [20]u8 = undefined;
        const id = try std.fmt.bufPrint(&buffer, "{d}", .{user_id});
        var result = try self.pool.query(
            "UPDATE web_sessions SET csrf_token_hash = $3::bytea WHERE user_id = $1 AND token_hash = $2::bytea AND revoked_at IS NULL AND expires_at > now() RETURNING id",
            &.{ id, token_hash, csrf_hash },
        );
        defer result.deinit();
        if (result.rowCount() != 1) return error.SessionNotFound;
    }

    /// handle everything in one transaction
    pub fn mutateAccount(self: *ApplicationRepository, actor: types.Actor, mutation: Mutation, input: ?AccountInput, password_hash: ?[]const u8, proof: SessionProof) !void {
        var buffer: [20]u8 = undefined;
        const id = try std.fmt.bufPrint(&buffer, "{d}", .{actor.user_id});
        var transaction = try self.pool.begin();
        errdefer transaction.rollback() catch {};

        // all account/admin mutations lock users before sessions.
        var owner = try transaction.query("SELECT id FROM users WHERE id = $1 FOR UPDATE", &.{id});
        owner.deinit();
        var consumed = try transaction.query(
            "UPDATE web_sessions SET csrf_token_hash = $4::bytea WHERE user_id = $1 AND token_hash = $2::bytea AND csrf_token_hash = $3::bytea AND revoked_at IS NULL AND expires_at > now() RETURNING id",
            &.{ id, &proof.token_hash, &proof.csrf_hash, &proof.next_csrf_hash },
        );
        const valid_session = consumed.rowCount() == 1;
        consumed.deinit();
        if (!valid_session) return error.CsrfTokenInvalid;

        // lock the application too to prevent concurrent submissions.
        var current = try transaction.query("SELECT status, client_type, minecraft_nickname FROM applications WHERE user_id = $1 FOR UPDATE", &.{id});
        defer current.deinit();
        const status = if (current.rowCount() == 1) std.meta.stringToEnum(types.ApplicationStatus, current.value(0, 0)).? else null;
        const client_type = if (current.rowCount() == 1) std.meta.stringToEnum(types.ClientType, current.value(0, 1)).? else null;
        try requireAction(actor, mutation, status, client_type);

        if (input) |content| {
            if (mutation == .resubmit) try domain.application.requireUnchangedNickname(current.value(0, 2), content.nickname);
            switch (content.client_type) {
                .cracked => if (content.password_hash == null) return error.PasswordRequiredForCracked,
                .licensed => if (content.password_hash != null) return error.PasswordNotAllowedForLicensed,
            }
            var conflict = try transaction.query("SELECT user_id FROM applications WHERE minecraft_nickname_normalized = $1 AND user_id <> $2", &.{ content.nickname.canonical(), id });
            const taken = conflict.rowCount() != 0;
            conflict.deinit();
            if (taken) return error.NicknameUnavailable;
            var changed = if (mutation == .create)
                try transaction.query(
                    "INSERT INTO applications (user_id, minecraft_nickname, minecraft_nickname_normalized, client_type, about_me, discovery_source) VALUES ($1, $2, $3, $4::minecraft_client_type, $5, $6)",
                    &.{ id, content.nickname.display(), content.nickname.canonical(), @tagName(content.client_type), content.about_me, content.discovery_source },
                )
            else
                try transaction.query(
                    "UPDATE applications SET client_type = $2::minecraft_client_type, about_me = $3, discovery_source = $4, status = 'pending', decision_reason = NULL, decided_at = NULL, decided_by_user_id = NULL, submitted_at = now(), updated_at = now() WHERE user_id = $1",
                    &.{ id, @tagName(content.client_type), content.about_me, content.discovery_source },
                );
            changed.deinit();
            if (content.password_hash) |hash| {
                var credential = try transaction.query("INSERT INTO password_credentials (user_id, password_hash) VALUES ($1, $2) ON CONFLICT (user_id) DO UPDATE SET password_hash = EXCLUDED.password_hash, changed_at = now()", &.{ id, hash });
                credential.deinit();
            } else {
                var deleted = try transaction.query("DELETE FROM password_credentials WHERE user_id = $1", &.{id});
                deleted.deinit();
            }
        } else {
            var credential = try transaction.query("INSERT INTO password_credentials (user_id, password_hash) VALUES ($1, $2) ON CONFLICT (user_id) DO UPDATE SET password_hash = EXCLUDED.password_hash, changed_at = now() RETURNING user_id", &.{ id, password_hash orelse return error.PasswordRequired });
            const updated = credential.rowCount() == 1;
            credential.deinit();
            if (!updated) return error.PasswordChangeNotAllowed;
        }
        const action = switch (mutation) {
            .create => "application_created",
            .resubmit => "application_resubmitted",
            .password => "password_changed",
        };
        var audit_result = try transaction.query("INSERT INTO audit_log (actor_user_id, subject_user_id, action, old_value, new_value, reason) VALUES ($1, $1, $2, NULL, NULL, NULL)", &.{ id, action });
        audit_result.deinit();
        try transaction.commit();
    }

    pub fn queue(self: *ApplicationRepository, options: Queue) !db.Result {
        var limit_buffer: [4]u8 = undefined;
        var time_buffer: [20]u8 = undefined;
        var id_buffer: [20]u8 = undefined;
        const limit = try std.fmt.bufPrint(&limit_buffer, "{d}", .{@as(u16, options.limit) + 1});
        const time = if (options.cursor_time) |value| try std.fmt.bufPrint(&time_buffer, "{d}", .{value}) else null;
        const id = if (options.cursor_id) |value| try std.fmt.bufPrint(&id_buffer, "{d}", .{value}) else null;
        return self.pool.query(
            "SELECT a.user_id, u.discord_id, COALESCE(u.discord_global_name,u.discord_username), a.minecraft_nickname, a.client_type, a.status, a.submitted_at, (extract(epoch FROM a.submitted_at)*1000000)::bigint FROM applications a JOIN users u ON u.id=a.user_id WHERE a.status=$1::application_status AND ($2::text IS NULL OR strpos(a.minecraft_nickname_normalized,lower($2))>0 OR u.discord_id=$2 OR u.id::text=$2) AND ($3::bigint IS NULL OR (a.submitted_at,a.user_id) > (TIMESTAMPTZ 'epoch' + $3::bigint * INTERVAL '1 microsecond',$4::bigint)) ORDER BY a.submitted_at ASC,a.user_id ASC LIMIT $5::integer",
            &.{ @tagName(options.status), options.query, time, id, limit },
        );
    }

    pub fn card(self: *ApplicationRepository, user_id: i64) !db.Result {
        var buffer: [20]u8 = undefined;
        const id = try std.fmt.bufPrint(&buffer, "{d}", .{user_id});
        return self.pool.query(
            "SELECT u.id,u.discord_id,u.discord_username,u.discord_global_name,u.discord_avatar_hash,a.minecraft_nickname,a.client_type,a.status,a.about_me,a.discovery_source,a.decision_reason,a.decision_reason IS NULL,a.submitted_at,a.decided_at,a.decided_by_user_id,NOT EXISTS(SELECT 1 FROM password_credentials WHERE user_id=u.id) FROM users u LEFT JOIN applications a ON a.user_id=u.id WHERE u.id=$1",
            &.{id},
        );
    }

    /// handle identity, csrf and changes in one transaction
    pub fn mutateAdmin(self: *ApplicationRepository, service: *auth.AuthService, actor_id: i64, subject_id: i64, mutation: AdminMutation, patch: AdminPatch, proof: SessionProof) !void {
        var actor_buffer: [20]u8 = undefined;
        var subject_buffer: [20]u8 = undefined;
        const actor = try std.fmt.bufPrint(&actor_buffer, "{d}", .{actor_id});
        const subject = try std.fmt.bufPrint(&subject_buffer, "{d}", .{subject_id});
        var transaction = try self.pool.begin();
        errdefer transaction.rollback() catch {};
        var locked = try transaction.query("SELECT id FROM users WHERE id IN ($1::bigint,$2::bigint) ORDER BY id FOR UPDATE", &.{ actor, subject });
        locked.deinit();
        var identity = try transaction.query("SELECT u.discord_id,a.status FROM users u LEFT JOIN applications a ON a.user_id=u.id WHERE u.id=$1", &.{actor});
        defer identity.deinit();
        if (identity.rowCount() != 1) return error.SessionNotFound;
        const role = auth.roleForDiscordId(service.configuration, identity.value(0, 0));
        if (!domain.application.canPerform(role, if (mutation == .edit) .edit_user_identity else if (mutation == .approve) .approve_application else .reject_application)) return error.InsufficientRole;
        if (std.mem.eql(u8, identity.value(0, 1), "banned") or std.mem.eql(u8, identity.value(0, 1), "rejected_final")) return error.AccountReadOnly;
        var consumed = try transaction.query("UPDATE web_sessions SET csrf_token_hash=$4::bytea WHERE user_id=$1 AND token_hash=$2::bytea AND csrf_token_hash=$3::bytea AND revoked_at IS NULL AND expires_at>now() RETURNING id", &.{ actor, &proof.token_hash, &proof.csrf_hash, &proof.next_csrf_hash });
        const valid = consumed.rowCount() == 1;
        consumed.deinit();
        if (!valid) return error.CsrfTokenInvalid;
        var current = try transaction.query("SELECT u.discord_id,a.minecraft_nickname,a.client_type,a.status FROM users u LEFT JOIN applications a ON a.user_id=u.id WHERE u.id=$1 FOR UPDATE OF u", &.{subject});
        defer current.deinit();
        if (current.rowCount() != 1) return error.UserNotFound;
        var application = try transaction.query("SELECT user_id FROM applications WHERE user_id=$1 FOR UPDATE", &.{subject});
        const has_application = application.rowCount() == 1;
        application.deinit();
        // re-read after locking to avoid stale data
        const status = std.meta.stringToEnum(types.ApplicationStatus, current.value(0, 3));
        if (mutation != .edit) {
            if (!has_application) return error.ApplicationNotFound;
            if (status != .pending) return error.ApplicationNotPending;
        } else if (!has_application and (patch.nickname != null or patch.client_type != null or patch.status != null)) return error.ApplicationNotFound;

        if (patch.nickname) |value| {
            if (!std.mem.eql(u8, value.display(), current.value(0, 1))) {
                var conflict = try transaction.query("SELECT user_id FROM applications WHERE minecraft_nickname_normalized=$1 AND user_id<>$2", &.{ value.canonical(), subject });
                const taken = conflict.rowCount() != 0;
                conflict.deinit();
                if (taken) return error.NicknameUnavailable;
                var savepoint = try transaction.query("SAVEPOINT identity_edit", &.{});
                savepoint.deinit();
                var changed = transaction.query("UPDATE applications SET minecraft_nickname=$2,minecraft_nickname_normalized=$3,updated_at=now() WHERE user_id=$1", &.{ subject, value.display(), value.canonical() }) catch |err| {
                    var restored = try transaction.query("ROLLBACK TO SAVEPOINT identity_edit", &.{});
                    restored.deinit();
                    var duplicate = try transaction.query("SELECT user_id FROM applications WHERE minecraft_nickname_normalized=$1 AND user_id<>$2", &.{ value.canonical(), subject });
                    defer duplicate.deinit();
                    if (duplicate.rowCount() != 0) return error.NicknameUnavailable;
                    return err;
                };
                changed.deinit();
                try writeAudit(&transaction, self.pool.allocator, actor, subject, .user_nickname_changed, .{ .nickname = current.value(0, 1) }, .{ .nickname = value.display() }, patch.reason);
            }
        }
        if (patch.discord_id) |value| {
            if (!std.mem.eql(u8, value, current.value(0, 0))) {
                var conflict = try transaction.query("SELECT id FROM users WHERE discord_id=$1 AND id<>$2", &.{ value, subject });
                const taken = conflict.rowCount() != 0;
                conflict.deinit();
                if (taken) return error.DiscordIdInUse;
                var savepoint = try transaction.query("SAVEPOINT discord_edit", &.{});
                savepoint.deinit();
                var changed = transaction.query("UPDATE users SET discord_id=$2,discord_username='',discord_global_name=NULL,discord_avatar_hash=NULL,updated_at=now() WHERE id=$1", &.{ subject, value }) catch |err| {
                    var restored = try transaction.query("ROLLBACK TO SAVEPOINT discord_edit", &.{});
                    restored.deinit();
                    var duplicate = try transaction.query("SELECT id FROM users WHERE discord_id=$1 AND id<>$2", &.{ value, subject });
                    defer duplicate.deinit();
                    if (duplicate.rowCount() != 0) return error.DiscordIdInUse;
                    return err;
                };
                changed.deinit();
                try users.revokeSessionsInTransaction(&transaction, subject);
                try writeAudit(&transaction, self.pool.allocator, actor, subject, .user_discord_id_changed, .{ .discord_id = current.value(0, 0) }, .{ .discord_id = value }, patch.reason);
            }
        }
        if (patch.client_type) |value| {
            const old = std.meta.stringToEnum(types.ClientType, current.value(0, 2)).?;
            if (value != old) {
                var changed = try transaction.query("UPDATE applications SET client_type=$2::minecraft_client_type,updated_at=now() WHERE user_id=$1", &.{ subject, @tagName(value) });
                changed.deinit();
                var deleted = try transaction.query("DELETE FROM password_credentials WHERE user_id=$1", &.{subject});
                deleted.deinit();
                try writeAudit(&transaction, self.pool.allocator, actor, subject, .user_client_type_changed, .{ .client_type = old }, .{ .client_type = value }, patch.reason);
            }
        }
        if (patch.status) |value| {
            if (!domain.application.canTransition(status.?, value)) return error.InvalidStatusTransition;
            const needs_reason = value == .banned or value == .rejected_retryable or value == .rejected_final;
            if (needs_reason and patch.reason == null) return error.ReasonRequired;
            var changed = try transaction.query("UPDATE applications SET status=$2::application_status,decision_reason=$3,decided_at=CASE WHEN $2='pending' THEN NULL ELSE now() END,decided_by_user_id=CASE WHEN $2='pending' THEN NULL ELSE $4::bigint END,submitted_at=CASE WHEN $2='pending' THEN now() ELSE submitted_at END,updated_at=now() WHERE user_id=$1", &.{ subject, @tagName(value), if (needs_reason) patch.reason else null, actor });
            changed.deinit();
            if (value == .banned) try users.revokeSessionsInTransaction(&transaction, subject);
            const action: domain.audit.AuditAction = if (value == .banned) .user_banned else if (status == .banned) .user_unbanned else switch (value) {
                .pending => .application_resubmitted,
                .approved => .application_approved,
                .rejected_retryable => .application_rejected_retryable,
                .rejected_final => .application_rejected_final,
                .banned => unreachable,
            };
            try writeAudit(&transaction, self.pool.allocator, actor, subject, action, .{ .status = status }, .{ .status = value }, patch.reason);
        }
        try transaction.commit();
    }

    pub fn create(self: *ApplicationRepository, input: CreateInput) !Application {
        switch (input.client_type) {
            .cracked => if (input.password_hash == null) return error.PasswordRequired,
            .licensed => if (input.password_hash != null) return error.PasswordNotAllowed,
        }

        var transaction = try self.pool.begin();
        errdefer transaction.rollback() catch {};

        var user_result = try transaction.query(
            "INSERT INTO users (discord_id, discord_username, discord_global_name, discord_avatar_hash) VALUES ($1, $2, $3, $4) RETURNING id",
            &.{ input.discord_id, input.discord_username, input.discord_global_name, input.discord_avatar_hash },
        );
        defer user_result.deinit();
        const user_id = try std.fmt.parseInt(i64, user_result.value(0, 0), 10);

        var user_id_buffer: [20]u8 = undefined;
        const user_id_parameter = try std.fmt.bufPrint(&user_id_buffer, "{d}", .{user_id});
        var application_result = try transaction.query(
            "INSERT INTO applications (user_id, minecraft_nickname, minecraft_nickname_normalized, client_type, about_me, discovery_source) VALUES ($1, $2, $3, $4::minecraft_client_type, $5, $6)",
            &.{ user_id_parameter, input.nickname.display(), input.nickname.canonical(), @tagName(input.client_type), input.about_me, input.discovery_source },
        );
        application_result.deinit();

        if (input.password_hash) |password_hash| {
            var credential_result = try transaction.query(
                "INSERT INTO password_credentials (user_id, password_hash) VALUES ($1, $2)",
                &.{ user_id_parameter, password_hash },
            );
            credential_result.deinit();
        }

        var audit_result = try transaction.query(
            "INSERT INTO audit_log (actor_user_id, subject_user_id, action, old_value, new_value, reason) VALUES (NULL, $1, 'application_created', NULL, NULL, NULL)",
            &.{user_id_parameter},
        );
        audit_result.deinit();

        try transaction.commit();
        return .{
            .user_id = user_id,
            .nickname = input.nickname,
            .client_type = input.client_type,
        };
    }

    pub fn replacePassword(self: *ApplicationRepository, user_id: i64, new_hash: []const u8) !void {
        var user_id_buffer: [20]u8 = undefined;
        const user_id_parameter = try std.fmt.bufPrint(&user_id_buffer, "{d}", .{user_id});
        var transaction = try self.pool.begin();
        errdefer transaction.rollback() catch {};

        var credential_result = try transaction.query(
            "WITH eligible_application AS (SELECT user_id FROM applications WHERE user_id = $1 AND client_type = 'cracked' AND status = 'approved' FOR UPDATE), updated_credential AS (UPDATE password_credentials SET password_hash = $2, changed_at = now() FROM eligible_application WHERE password_credentials.user_id = eligible_application.user_id RETURNING password_credentials.user_id) SELECT EXISTS(SELECT 1 FROM updated_credential)",
            &.{ user_id_parameter, new_hash },
        );
        const credential_updated = std.mem.eql(u8, credential_result.value(0, 0), "t");
        credential_result.deinit();
        if (!credential_updated) return error.PasswordChangeNotAllowed;

        var audit_result = try transaction.query(
            "INSERT INTO audit_log (actor_user_id, subject_user_id, action, old_value, new_value, reason) VALUES (NULL, $1, 'password_changed', NULL, NULL, NULL)",
            &.{user_id_parameter},
        );
        audit_result.deinit();

        try transaction.commit();
    }
};
