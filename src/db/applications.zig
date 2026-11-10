const std = @import("std");
const db = @import("db_pool");
const domain = @import("domain");

const nickname = domain.nickname;
const types = domain.types;

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
            "SELECT users.id, users.discord_id, COALESCE(users.discord_global_name, users.discord_username), applications.minecraft_nickname, applications.client_type, applications.status, applications.decision_reason, applications.decision_reason IS NULL FROM users LEFT JOIN applications ON applications.user_id = users.id WHERE users.id = $1",
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

        var consumed = try transaction.query(
            "UPDATE web_sessions SET csrf_token_hash = $4::bytea WHERE user_id = $1 AND token_hash = $2::bytea AND csrf_token_hash = $3::bytea AND revoked_at IS NULL AND expires_at > now() RETURNING id",
            &.{ id, &proof.token_hash, &proof.csrf_hash, &proof.next_csrf_hash },
        );
        const valid_session = consumed.rowCount() == 1;
        consumed.deinit();
        if (!valid_session) return error.CsrfTokenInvalid;

        // lock both to prevent concurrent submissions.
        var owner = try transaction.query("SELECT id FROM users WHERE id = $1 FOR UPDATE", &.{id});
        owner.deinit();
        var current = try transaction.query("SELECT status, client_type FROM applications WHERE user_id = $1 FOR UPDATE", &.{id});
        defer current.deinit();
        const status = if (current.rowCount() == 1) std.meta.stringToEnum(types.ApplicationStatus, current.value(0, 0)).? else null;
        const client_type = if (current.rowCount() == 1) std.meta.stringToEnum(types.ClientType, current.value(0, 1)).? else null;
        try requireAction(actor, mutation, status, client_type);

        if (input) |content| {
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
                    "UPDATE applications SET minecraft_nickname = $2, minecraft_nickname_normalized = $3, client_type = $4::minecraft_client_type, about_me = $5, discovery_source = $6, status = 'pending', decision_reason = NULL, decided_at = NULL, decided_by_user_id = NULL, submitted_at = now(), updated_at = now() WHERE user_id = $1",
                    &.{ id, content.nickname.display(), content.nickname.canonical(), @tagName(content.client_type), content.about_me, content.discovery_source },
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
            var credential = try transaction.query("UPDATE password_credentials SET password_hash = $2, changed_at = now() WHERE user_id = $1 RETURNING user_id", &.{ id, password_hash orelse return error.PasswordRequired });
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
