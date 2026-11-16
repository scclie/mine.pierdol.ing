const std = @import("std");
const real = @import("game_auth_repository");
pub const Identity = real.Identity;
pub const Decision = real.Decision;
pub const Lease = real.Lease;
pub const Policy = enum { denied, cracked, licensed };
pub const Snapshot = struct {
    version: u64 = 42,
    unchanged: bool = false,
    identities: []Identity,
    pub fn deinit(self: *Snapshot, a: std.mem.Allocator) void {
        for (self.identities) |*i| i.deinit(a);
        a.free(self.identities);
    }
};
pub const token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
pub const uuid = "a01e3843-e521-3998-958a-f459800e4d11";
pub const Repository = struct {
    allocator: std.mem.Allocator,
    allow: bool = false,
    storage_failure: bool = false,
    audit_failure: bool = false,
    issue_failure: bool = false,
    stale_binding: bool = false,
    populated: bool = false,
    last_audit_outcome: []const u8 = "",
    last_audit_reason: []const u8 = "",
    policy: Policy = .denied,
    snapshot_calls: usize = 0,
    last_cursor: ?u64 = null,
    pub fn whitelistSnapshot(self: *@This(), cursor: ?u64) !Snapshot {
        self.snapshot_calls += 1;
        self.last_cursor = cursor;
        if (self.storage_failure) return error.StorageUnavailable;
        const identities = try self.allocator.alloc(Identity, if (self.populated and cursor != 42) 1 else 0);
        errdefer self.allocator.free(identities);
        if (identities.len != 0) identities[0] = try self.identity();
        return .{ .unchanged = cursor == 42, .identities = identities };
    }
    pub fn nicknamePolicy(self: *@This(), _: []const u8) !Policy {
        if (self.storage_failure) return error.StorageUnavailable;
        return self.policy;
    }
    pub fn authenticateCracked(self: *@This(), _: []const u8, _: []const u8) !Decision {
        return self.decision();
    }
    pub fn verifyPremium(self: *@This(), _: []const u8, _: []const u8) !Decision {
        return self.decision();
    }
    fn identity(self: *@This()) !Identity {
        const nickname = try self.allocator.dupe(u8, "Player");
        errdefer self.allocator.free(nickname);
        const canonical = try self.allocator.dupe(u8, "player");
        errdefer self.allocator.free(canonical);
        return .{ .identity_id = 11, .authentication_generation = 3, .user_id = 7, .nickname = nickname, .canonical_nickname = canonical, .client_type = .cracked, .uuid = try self.allocator.dupe(u8, uuid) };
    }
    fn decision(self: *@This()) !Decision {
        if (self.storage_failure) return error.StorageUnavailable;
        return if (self.allow) .{ .allow = try self.identity() } else .deny;
    }
    pub fn issueLease(self: *@This(), _: []const u8, _: Identity) !?Lease {
        if (self.storage_failure or self.issue_failure) return error.StorageUnavailable;
        if (self.stale_binding) return null;
        return .{ .token = token.*, .expires_at = 1730000000 };
    }
    pub fn checkLease(self: *@This(), _: []const u8, input: []const u8) !real.LeaseDecision {
        if (self.storage_failure) return error.StorageUnavailable;
        if (!self.allow or !std.mem.eql(u8, input, token)) return .disconnect;
        return .{ .continue_session = .{ .identity = try self.identity(), .lease = .{ .token = token.*, .expires_at = 1730000000 } } };
    }
    pub fn audit(self: *@This(), _: []const u8, _: ?i64, outcome: []const u8, reason: []const u8) !void {
        if (self.audit_failure) return error.AuditUnavailable;
        self.last_audit_outcome = outcome;
        self.last_audit_reason = reason;
    }
    pub fn whitelistVersion(self: *@This()) !u64 {
        _ = self;
        return 42;
    }
};
