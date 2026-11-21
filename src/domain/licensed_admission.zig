const std = @import("std");
const Uuid = @import("mojang_uuid.zig").Uuid;
const nickname = @import("nickname.zig");
const types = @import("types.zig");
const application = @import("application.zig");

pub const Operation = enum { create, resubmit, edit, approve, reject, resolve };
pub const UuidIntent = union(enum) { unchanged, clear, set: Uuid };
pub const ApplicationState = struct {
    nickname: nickname.CanonicalNickname,
    client_type: types.ClientType,
    status: types.ApplicationStatus,
};
pub const Snapshot = struct {
    revision: u64,
    application: ?ApplicationState,
    identity_id: ?i64,
    uuid: ?Uuid,
};
pub const Intent = struct {
    operation: Operation,
    nickname: ?nickname.CanonicalNickname = null,
    client_type: ?types.ClientType = null,
    status: ?types.ApplicationStatus = null,
    uuid: UuidIntent = .unchanged,
    confirmed_override: bool = false,
    has_reason: bool = false,
};
pub const Decision = struct {
    final: ApplicationState,
    lookup_required: bool,
    manual: ?Uuid,
    clear: bool,
};
pub const Observation = struct {
    requested: nickname.CanonicalNickname,
    returned: nickname.CanonicalNickname,
    uuid: Uuid,
    observed_ns: u64,
};
pub const Prepared = struct {
    expected: ?Snapshot,
    intent: Intent,
    observation: ?Observation,
};

pub fn evaluate(current: ?Snapshot, intent: Intent) !Decision {
    const previous: ?ApplicationState = if (current) |state| state.application else null;
    if (intent.operation == .create) {
        if (previous != null) return error.InvalidTransition;
    } else {
        if (previous == null) return error.ApplicationRequired;
        if (current.?.identity_id == null) return error.GameIdentityRequired;
    }

    const final = ApplicationState{
        .nickname = intent.nickname orelse if (previous) |old| old.nickname else return error.InvalidNickname,
        .client_type = intent.client_type orelse if (previous) |old| old.client_type else return error.ClientTypeRequired,
        .status = switch (intent.operation) {
            .create, .resubmit => .pending,
            .approve => .approved,
            else => intent.status orelse previous.?.status,
        },
    };
    if (intent.status) |status| {
        if (status != final.status) return error.InvalidTransition;
    }
    if (previous) |old| {
        if (old.status != final.status and !application.canTransition(old.status, final.status)) return error.InvalidTransition;
        switch (intent.operation) {
            .approve => if (old.status != .pending) return error.InvalidTransition,
            .resubmit => {
                if (old.status != .rejected_retryable) return error.InvalidTransition;
                try application.requireUnchangedNickname(old.nickname.display(), final.nickname);
            },
            .resolve => {
                if (old.client_type != .licensed or current.?.uuid != null or final.client_type != .licensed) return error.InvalidTransition;
            },
            else => {},
        }
    }
    if (intent.operation == .reject and final.status != .rejected_retryable and final.status != .rejected_final) return error.InvalidTransition;

    var manual: ?Uuid = null;
    switch (intent.uuid) {
        .unchanged => {},
        .clear => if (final.client_type == .licensed) return error.InvalidLicensedMojangUuid,
        .set => |uuid| {
            if (final.client_type == .cracked) return error.InvalidLicensedMojangUuid;
            if (!intent.confirmed_override or !intent.has_reason) return error.ManualOverrideRequired;
            manual = uuid;
        },
    }
    const lookup_required = final.client_type == .licensed and
        (intent.operation == .create or intent.operation == .resubmit or intent.operation == .resolve or
        (if (previous) |old| old.client_type == .cracked or
        !std.mem.eql(u8, old.nickname.display(), final.nickname.display()) or
        (old.status != .approved and final.status == .approved) else false));
    return .{ .final = final, .lookup_required = lookup_required, .manual = manual, .clear = final.client_type == .cracked };
}

pub fn binding(current: ?Snapshot, decision: Decision, observation: ?Observation) !?Uuid {
    if (observation) |found| {
        if (!std.mem.eql(u8, found.requested.canonical(), found.returned.canonical())) return error.IdentityChanged;
    }
    if (decision.clear) return null;
    if (decision.lookup_required) {
        const found = observation orelse return error.MojangObservationRequired;
        if (!std.mem.eql(u8, found.requested.display(), decision.final.nickname.display())) return error.IdentityChanged;
        if (decision.manual) |manual| {
            if (!manual.eql(found.uuid)) return error.LicensedMojangUuidMismatch;
            return manual;
        }
        if (current) |state| {
            if (state.uuid) |old| {
                if (!old.eql(found.uuid)) return error.LicensedMojangUuidMismatch;
            }
        }
        return found.uuid;
    }
    if (decision.manual) |manual| return manual;
    return if (current) |state| state.uuid else null;
}
