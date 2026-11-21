const std = @import("std");
const db = @import("db_pool");
const domain = @import("domain");
const auth = @import("auth");
const users = @import("users");
const mojang = @import("mojang");

const nickname = domain.nickname;
const types = domain.types;
const admission = domain.licensed_admission;
const Uuid = domain.mojang_uuid.Uuid;
const UuidSource = domain.audit.UuidSource;

const admission_snapshot_sql =
    "SELECT u.application_revision,a.minecraft_nickname,a.client_type,a.status,gi.identity_id,gi.licensed_mojang_uuid::text,a.user_id IS NOT NULL,gi.identity_id IS NOT NULL FROM users u LEFT JOIN applications a ON a.user_id=u.id LEFT JOIN game_identities gi ON gi.user_id=u.id WHERE u.id=$1";

fn decodeAdmissionSnapshot(result: *const db.Result) !admission.Snapshot {
    if (result.rowCount() != 1) return error.UserNotFound;
    return .{
        .revision = try std.fmt.parseInt(u64, result.value(0, 0), 10),
        .application = if (std.mem.eql(u8, result.value(0, 6), "t")) .{
            .nickname = try nickname.validateNickname(result.value(0, 1)),
            .client_type = std.meta.stringToEnum(types.ClientType, result.value(0, 2)) orelse return error.QueryFailed,
            .status = std.meta.stringToEnum(types.ApplicationStatus, result.value(0, 3)) orelse return error.QueryFailed,
        } else null,
        .identity_id = if (std.mem.eql(u8, result.value(0, 7), "t")) try std.fmt.parseInt(i64, result.value(0, 4), 10) else null,
        .uuid = if (result.value(0, 5).len != 0) try Uuid.parseAdmin(result.value(0, 5)) else null,
    };
}

/// caller locks users by id first, then application/identity rows
/// read fresh values after locking
pub fn readLockedAdmissionSnapshot(transaction: *db.Transaction, user_id: i64) !admission.Snapshot {
    var buffer: [20]u8 = undefined;
    const id = try std.fmt.bufPrint(&buffer, "{d}", .{user_id});
    var application = try transaction.query("SELECT user_id FROM applications WHERE user_id=$1 FOR UPDATE", &.{id});
    application.deinit();
    var identity = try transaction.query("SELECT identity_id FROM game_identities WHERE user_id=$1 FOR UPDATE", &.{id});
    identity.deinit();
    var result = try transaction.query(admission_snapshot_sql, &.{id});
    defer result.deinit();
    return decodeAdmissionSnapshot(&result);
}

fn sameUuid(left: ?Uuid, right: ?Uuid) bool {
    if (left) |value| return if (right) |other| value.eql(other) else false;
    return right == null;
}

fn requireAccountIntent(prepared: admission.Prepared, mutation: Mutation, name: nickname.CanonicalNickname, client_type: types.ClientType) !void {
    if (prepared.intent.operation != (if (mutation == .create) admission.Operation.create else .resubmit) or
        prepared.intent.uuid != .unchanged or prepared.intent.confirmed_override or prepared.intent.has_reason or
        prepared.intent.status != null or prepared.intent.nickname == null or prepared.intent.client_type != client_type or
        !std.mem.eql(u8, prepared.intent.nickname.?.display(), name.display())) return error.IdentityChanged;
}

fn validateObservationTime(prepared: admission.Prepared, now: u64) !void {
    if (prepared.observation) |found| {
        if (found.observed_ns > now or now - found.observed_ns > 10 * std.time.ns_per_s) return error.IdentityChanged;
    }
}

/// validate existing owner only, no lookups, clock reads or sql changes
pub fn validatePrepared(current: admission.Snapshot, prepared: admission.Prepared, now_ns: u64) !admission.Decision {
    const expected = prepared.expected orelse return error.IdentityChanged;
    if (current.revision != expected.revision or current.identity_id != expected.identity_id or
        !sameUuid(current.uuid, expected.uuid)) return error.IdentityChanged;
    if (current.application) |value| {
        const old = expected.application orelse return error.IdentityChanged;
        if (!std.mem.eql(u8, value.nickname.display(), old.nickname.display()) or
            value.client_type != old.client_type or value.status != old.status) return error.IdentityChanged;
        if (current.identity_id == null) return error.GameIdentityMissing;
    } else if (expected.application != null) return error.IdentityChanged;

    const decision = try admission.evaluate(current, prepared.intent);
    if (prepared.observation) |observation| {
        if (observation.observed_ns > now_ns or now_ns - observation.observed_ns > 10 * std.time.ns_per_s or
            !std.mem.eql(u8, observation.requested.display(), decision.final.nickname.display())) return error.IdentityChanged;
    }
    _ = try admission.binding(current, decision, prepared.observation);
    return decision;
}

/// requires locked policy/binding checks, all changes use caller's transaction
/// rollback on any error
pub fn writeLicensedBinding(transaction: *db.Transaction, allocator: std.mem.Allocator, actor: ?i64, subject: i64, old: ?Uuid, new: ?Uuid, source: UuidSource, reason: ?[]const u8, reaffirm: bool) !void {
    const unchanged = sameUuid(old, new);
    const manual_reaffirmation = unchanged and source == .manual_admin and reaffirm;
    if (unchanged and !manual_reaffirmation) return;

    var subject_buffer: [20]u8 = undefined;
    var actor_buffer: [20]u8 = undefined;
    const subject_text = try std.fmt.bufPrint(&subject_buffer, "{d}", .{subject});
    const actor_text = if (actor) |id| try std.fmt.bufPrint(&actor_buffer, "{d}", .{id}) else null;
    var old_buffer: [36]u8 = undefined;
    var new_buffer: [36]u8 = undefined;
    const old_text: ?[]const u8 = if (old) |uuid| blk: {
        old_buffer = uuid.format();
        break :blk &old_buffer;
    } else null;
    const new_text: ?[]const u8 = if (new) |uuid| blk: {
        new_buffer = uuid.format();
        break :blk &new_buffer;
    } else null;
    if (!unchanged) {
        var set = try transaction.query("SELECT application_set_licensed_uuid($1::bigint,$2::uuid)", &.{ subject_text, new_text });
        defer set.deinit();
        const result = set.value(0, 0);
        if (std.mem.eql(u8, result, "in_use")) return error.LicensedMojangUuidInUse;
        if (std.mem.eql(u8, result, "missing")) return error.GameIdentityMissing;
        if (!std.mem.eql(u8, result, "updated")) return error.QueryFailed;
    }
    const before = try domain.audit.serializeUuid(allocator, old_text, source);
    defer allocator.free(before);
    const after = try domain.audit.serializeUuid(allocator, new_text, source);
    defer allocator.free(after);
    var audit = try transaction.query("INSERT INTO audit_log (actor_user_id,subject_user_id,action,old_value,new_value,reason) VALUES ($1,$2,'licensed_mojang_uuid_changed',$3::jsonb,$4::jsonb,$5)", &.{ actor_text, subject_text, before, after, if (source == .manual_admin) reason else @tagName(source) });
    audit.deinit();
    if (manual_reaffirmation) {
        var revision = try transaction.query("UPDATE users SET application_revision=application_revision+1 WHERE id=$1", &.{subject_text});
        revision.deinit();
    }
}

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
    uuid: admission.UuidIntent = .unchanged,
    confirmed_override: bool = false,
    resolve_uuid: bool = false,
    expected_revision: ?u64 = null,
};

pub const AdminMutation = enum { approve, reject, edit };

/// shared preflight and locked policy
pub fn adminIntent(snapshot: admission.Snapshot, mutation: AdminMutation, patch: AdminPatch) !admission.Intent {
    if (patch.expected_revision) |revision| if (revision != snapshot.revision) return error.IdentityChanged;
    const app = snapshot.application orelse {
        if (mutation != .edit or patch.nickname != null or patch.client_type != null or patch.status != null or patch.uuid != .unchanged or patch.resolve_uuid) return error.ApplicationNotFound;
        return .{ .operation = .edit };
    };
    if (snapshot.identity_id == null) return error.GameIdentityMissing;
    if (mutation != .edit and app.status != .pending) return error.ApplicationNotPending;
    if (patch.status) |status| {
        if (!domain.application.canTransition(app.status, status)) return error.InvalidStatusTransition;
        if ((status == .banned or status == .rejected_retryable or status == .rejected_final) and patch.reason == null) return error.ReasonRequired;
    }
    const client = patch.client_type orelse app.client_type;
    if (patch.resolve_uuid) {
        if (patch.uuid != .unchanged or patch.confirmed_override or patch.nickname != null or patch.client_type != null or patch.status != null or patch.discord_id != null) return error.InvalidUuidOperation;
        if (client != .licensed) return error.LicensedMojangUuidNotApplicable;
        if (snapshot.uuid != null) return error.LicensedMojangUuidAlreadyResolved;
    }
    switch (patch.uuid) {
        .unchanged => if (patch.confirmed_override) return error.InvalidUuidOperation,
        .clear => {
            if (client == .licensed) return error.LicensedMojangUuidRequired;
            if (patch.confirmed_override) return error.InvalidUuidOperation;
        },
        .set => {
            if (client != .licensed) return error.LicensedMojangUuidNotApplicable;
            if (!patch.confirmed_override) return error.UuidOverrideConfirmationRequired;
            if (patch.reason == null) return error.ReasonRequired;
        },
    }
    return .{ .operation = if (patch.resolve_uuid) .resolve else switch (mutation) {
        .approve => .approve,
        .reject => .reject,
        .edit => .edit,
    }, .nickname = patch.nickname, .client_type = patch.client_type, .status = patch.status, .uuid = patch.uuid, .confirmed_override = patch.confirmed_override, .has_reason = patch.reason != null };
}

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

    /// Owned fixed-size values; no SQL result or borrowed field escapes.
    pub fn readAdmissionSnapshot(self: *ApplicationRepository, user_id: i64) !admission.Snapshot {
        var buffer: [20]u8 = undefined;
        const id = try std.fmt.bufPrint(&buffer, "{d}", .{user_id});
        var result = try self.pool.query(admission_snapshot_sql, &.{id});
        defer result.deinit();
        return decodeAdmissionSnapshot(&result);
    }

    /// only expose public account data.
    pub fn account(self: *ApplicationRepository, user_id: i64) !db.Result {
        var buffer: [20]u8 = undefined;
        const id = try std.fmt.bufPrint(&buffer, "{d}", .{user_id});
        return self.pool.query(
            "SELECT users.id, users.discord_id, COALESCE(users.discord_global_name, users.discord_username), applications.minecraft_nickname, applications.client_type, applications.status, applications.decision_reason, applications.decision_reason IS NULL, NOT EXISTS (SELECT 1 FROM password_credentials WHERE user_id = users.id), users.discord_username FROM users LEFT JOIN applications ON applications.user_id = users.id WHERE users.id = $1",
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
    pub fn mutateAccount(self: *ApplicationRepository, actor: types.Actor, mutation: Mutation, input: ?AccountInput, password_hash: ?[]const u8, proof: SessionProof, auth_service: *auth.AuthService, prepared: ?admission.Prepared, clock: *const mojang.Clock) !void {
        // legacy lock order may cause deadlocks.
        // retry only confirmed deadlocks after a full rollback.
        // recheck session, permissions and nickname under fresh locks.
        for (0..3) |attempt| {
            var transaction = try self.pool.begin();
            mutateAccountTransaction(&transaction, actor, mutation, input, password_hash, proof, auth_service, prepared, clock) catch |err| {
                try transaction.rollback();
                if (err == error.DeadlockDetected and attempt < 2) continue;
                return err;
            };
            // an unknown COMMIT outcome must never be retried.
            transaction.commit() catch |err| {
                transaction.rollback() catch {};
                return err;
            };
            return;
        }
    }

    fn mutateAccountTransaction(transaction: *db.Transaction, actor: types.Actor, mutation: Mutation, input: ?AccountInput, password_hash: ?[]const u8, proof: SessionProof, auth_service: *auth.AuthService, prepared: ?admission.Prepared, clock: *const mojang.Clock) !void {
        var buffer: [20]u8 = undefined;
        const id = try std.fmt.bufPrint(&buffer, "{d}", .{actor.user_id});

        // all account/admin mutations lock users before sessions.
        var owner = try transaction.query("SELECT id FROM users WHERE id = $1 FOR UPDATE", &.{id});
        owner.deinit();
        var identity = try transaction.query("SELECT discord_id FROM users WHERE id=$1", &.{id});
        if (identity.rowCount() != 1) {
            identity.deinit();
            return error.SessionNotFound;
        }
        const role = auth.roleForDiscordId(auth_service.configuration, identity.value(0, 0));
        identity.deinit();
        var consumed = try transaction.query(
            "UPDATE web_sessions SET csrf_token_hash = $4::bytea WHERE user_id = $1 AND token_hash = $2::bytea AND csrf_token_hash = $3::bytea AND revoked_at IS NULL AND expires_at > now() RETURNING id",
            &.{ id, &proof.token_hash, &proof.csrf_hash, &proof.next_csrf_hash },
        );
        const valid_session = consumed.rowCount() == 1;
        consumed.deinit();
        if (!valid_session) return error.CsrfTokenInvalid;

        const current = try readLockedAdmissionSnapshot(transaction, actor.user_id);
        var binding: ?Uuid = null;
        if (mutation != .password) {
            const evidence = prepared orelse return error.MojangObservationRequired;
            const content = input orelse return error.InvalidTransition;
            try requireAccountIntent(evidence, mutation, content.nickname, content.client_type);
            const decision = try validatePrepared(current, evidence, clock.now());
            binding = try admission.binding(current, decision, evidence.observation);
        } else if (input != null or prepared != null) return error.InvalidTransition;
        const status = if (current.application) |app| app.status else null;
        const client_type = if (current.application) |app| app.client_type else null;
        try requireAction(.{ .user_id = actor.user_id, .role = role }, mutation, status, client_type);

        if (input) |content| {
            if (mutation == .resubmit) try domain.application.requireUnchangedNickname(current.application.?.nickname.display(), content.nickname);
            switch (content.client_type) {
                .cracked => if (content.password_hash == null) return error.PasswordRequiredForCracked,
                .licensed => if (content.password_hash != null) return error.PasswordNotAllowedForLicensed,
            }
            var conflict = try transaction.query("SELECT user_id FROM applications WHERE minecraft_nickname_normalized = $1 AND user_id <> $2", &.{ content.nickname.canonical(), id });
            const taken = conflict.rowCount() != 0;
            conflict.deinit();
            if (taken) return error.NicknameUnavailable;
            if (client_type != null and client_type.? != content.client_type) {
                var deleted = try transaction.query("DELETE FROM password_credentials WHERE user_id=$1", &.{id});
                deleted.deinit();
            }
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
            const inserted = try readLockedAdmissionSnapshot(transaction, actor.user_id);
            if (inserted.identity_id == null) return error.GameIdentityMissing;
            try writeLicensedBinding(transaction, auth_service.allocator, actor.user_id, actor.user_id, current.uuid, binding, if (content.client_type == .cracked) .cracked_clear else .mojang_lookup, null, false);
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
            "SELECT u.id,u.discord_id,u.discord_username,u.discord_global_name,u.discord_avatar_hash,a.minecraft_nickname,a.client_type,a.status,a.about_me,a.discovery_source,a.decision_reason,a.decision_reason IS NULL,a.submitted_at,a.decided_at,a.decided_by_user_id,NOT EXISTS(SELECT 1 FROM password_credentials WHERE user_id=u.id),gi.licensed_mojang_uuid::text,u.application_revision::text FROM users u LEFT JOIN applications a ON a.user_id=u.id LEFT JOIN game_identities gi ON gi.user_id=u.id WHERE u.id=$1",
            &.{id},
        );
    }

    /// handle identity, csrf and changes in one transaction
    pub fn mutateAdmin(self: *ApplicationRepository, service: *auth.AuthService, actor_id: i64, subject_id: i64, mutation: AdminMutation, patch: AdminPatch, proof: SessionProof, prepared: admission.Prepared, clock: *const mojang.Clock) !void {
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
        const snapshot = try readLockedAdmissionSnapshot(&transaction, subject_id);
        if (prepared.expected == null or !std.meta.eql(snapshot, prepared.expected.?)) return error.IdentityChanged;
        const intent = try adminIntent(snapshot, mutation, patch);
        if (!std.meta.eql(intent, prepared.intent)) return error.IdentityChanged;
        var binding: ?Uuid = null;
        var binding_source: UuidSource = .mojang_lookup;
        if (snapshot.application != null) {
            const decision = try validatePrepared(snapshot, prepared, clock.now());
            binding = try admission.binding(snapshot, decision, prepared.observation);
            binding_source = if (decision.clear) .cracked_clear else if (decision.manual != null) .manual_admin else .mojang_lookup;
        } else if (prepared.expected == null or !std.meta.eql(snapshot, prepared.expected.?)) return error.IdentityChanged;
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
        if (snapshot.application != null) try writeLicensedBinding(&transaction, self.pool.allocator, actor_id, subject_id, snapshot.uuid, binding, binding_source, patch.reason, patch.uuid == .set);
        try transaction.commit();
    }

    pub fn create(self: *ApplicationRepository, input: CreateInput, prepared: admission.Prepared, clock: *const mojang.Clock) !Application {
        switch (input.client_type) {
            .cracked => if (input.password_hash == null) return error.PasswordRequired,
            .licensed => if (input.password_hash != null) return error.PasswordNotAllowed,
        }

        var transaction = try self.pool.begin();
        errdefer transaction.rollback() catch {};
        if (prepared.expected != null) return error.IdentityChanged;
        try requireAccountIntent(prepared, .create, input.nickname, input.client_type);
        const decision = try admission.evaluate(null, prepared.intent);
        try validateObservationTime(prepared, clock.now());
        const binding = try admission.binding(null, decision, prepared.observation);
        var conflict = try transaction.query("SELECT 1 FROM users WHERE discord_id=$1", &.{input.discord_id});
        const discord_taken = conflict.rowCount() != 0;
        conflict.deinit();
        if (discord_taken) return error.DiscordIdInUse;
        var nickname_conflict = try transaction.query("SELECT 1 FROM applications WHERE minecraft_nickname_normalized=$1", &.{input.nickname.canonical()});
        const nickname_taken = nickname_conflict.rowCount() != 0;
        nickname_conflict.deinit();
        if (nickname_taken) return error.NicknameUnavailable;

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
        const inserted = try readLockedAdmissionSnapshot(&transaction, user_id);
        if (inserted.identity_id == null) return error.GameIdentityMissing;
        try writeLicensedBinding(&transaction, self.pool.allocator, null, user_id, null, binding, .mojang_lookup, null, false);

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

        // use consistent lock order: user before application, credentials and identity
        var owner = try transaction.query("SELECT id FROM users WHERE id=$1::bigint FOR UPDATE", &.{user_id_parameter});
        owner.deinit();

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
