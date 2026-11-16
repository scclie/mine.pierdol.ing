const std = @import("std");
const db = @import("db_pool");
const domain = @import("domain");

const types = domain.types;

pub const Identity = struct {
    identity_id: i64,
    authentication_generation: u64,
    user_id: i64,
    nickname: []const u8,
    canonical_nickname: []const u8,
    client_type: types.ClientType,
    uuid: []const u8,

    pub fn deinit(self: *Identity, allocator: std.mem.Allocator) void {
        allocator.free(self.nickname);
        allocator.free(self.canonical_nickname);
        allocator.free(self.uuid);
    }
};

pub const Snapshot = struct {
    version: u64,
    unchanged: bool = false,
    identities: []Identity,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        for (self.identities) |*identity| identity.deinit(allocator);
        allocator.free(self.identities);
    }
};

pub const Decision = union(enum) {
    allow: Identity,
    deny: void,
};

pub const Policy = enum { denied, cracked, licensed };

pub fn policyFor(client_type: ?[]const u8, status: ?[]const u8) !Policy {
    const current_status = status orelse return .denied;
    if (!std.mem.eql(u8, current_status, "approved")) return .denied;
    const current_type = client_type orelse return .denied;
    const parsed = std.meta.stringToEnum(types.ClientType, current_type) orelse return error.InvalidClientType;
    return switch (parsed) {
        .cracked => .cracked,
        .licensed => .licensed,
    };
}

pub const Lease = struct {
    token: [64]u8,
    expires_at: i64,
};

pub const LeaseDecision = union(enum) {
    continue_session: struct { identity: Identity, lease: Lease },
    disconnect: void,
};

pub const Repository = struct {
    pool: *db.Pool,

    pub fn init(pool: *db.Pool) Repository {
        return .{ .pool = pool };
    }

    pub fn whitelistSnapshot(self: *Repository, cursor: ?u64) !Snapshot {
        var cursor_buffer: [20]u8 = undefined;
        const cursor_parameter = if (cursor) |value| try std.fmt.bufPrint(&cursor_buffer, "{d}", .{value}) else null;
        var rows = try self.pool.query(
            "SELECT a.user_id,a.minecraft_nickname,a.minecraft_nickname_normalized,a.client_type,gi.licensed_mojang_uuid::text,gi.identity_id,gi.authentication_generation,s.version FROM game_auth_whitelist_state s LEFT JOIN (applications a JOIN game_identities gi ON gi.user_id=a.user_id) ON a.status='approved' AND (a.client_type='cracked' OR gi.licensed_mojang_uuid IS NOT NULL) AND ($1::bigint IS NULL OR s.version<>$1::bigint) WHERE s.singleton=TRUE ORDER BY a.minecraft_nickname_normalized ASC",
            &.{cursor_parameter},
        );
        defer rows.deinit();
        if (rows.rowCount() == 0) return error.WhitelistStateNotFound;
        const version = try std.fmt.parseInt(u64, rows.value(0, 7), 10);

        var identities = try std.ArrayList(Identity).initCapacity(self.pool.allocator, rows.rowCount());
        errdefer {
            for (identities.items) |*identity| identity.deinit(self.pool.allocator);
            identities.deinit();
        }
        for (0..rows.rowCount()) |index| {
            if (rows.value(index, 0).len == 0) continue;
            const client_type = std.meta.stringToEnum(types.ClientType, rows.value(index, 3)) orelse return error.InvalidClientType;
            const uuid = if (client_type == .cracked) try offlineUuid(self.pool.allocator, rows.value(index, 1)) else try self.pool.allocator.dupe(u8, rows.value(index, 4));
            const identity = identityFromRow(self.pool.allocator, &rows, index, client_type, uuid) catch |err| {
                self.pool.allocator.free(uuid);
                return err;
            };
            identities.append(identity) catch |err| {
                var cleanup = identity;
                cleanup.deinit(self.pool.allocator);
                return err;
            };
        }
        return .{ .version = version, .unchanged = cursor != null and cursor.? == version, .identities = try identities.toOwnedSlice() };
    }

    pub fn nicknamePolicy(self: *Repository, canonical_nickname: []const u8) !Policy {
        var rows = try self.pool.query("SELECT client_type,status FROM applications WHERE minecraft_nickname_normalized=$1", &.{canonical_nickname});
        defer rows.deinit();
        if (rows.rowCount() == 0) return policyFor(null, null);
        if (rows.rowCount() != 1) return error.IdentityNotUnique;
        return policyFor(rows.value(0, 0), rows.value(0, 1));
    }

    pub fn authenticateCracked(self: *Repository, canonical_nickname: []const u8, password: []const u8) !Decision {
        var row = try self.pool.query(
            "SELECT a.user_id,a.minecraft_nickname,a.minecraft_nickname_normalized,a.client_type,pc.password_hash,gi.identity_id,gi.authentication_generation FROM applications a JOIN password_credentials pc ON pc.user_id=a.user_id JOIN game_identities gi ON gi.user_id=a.user_id WHERE a.minecraft_nickname_normalized=$1 AND a.client_type='cracked' AND a.status='approved'",
            &.{canonical_nickname},
        );
        defer row.deinit();
        if (row.rowCount() != 1) return .deny;
        if (!try domain.password.verifyPassword(row.value(0, 4), password)) return .deny;
        const uuid = try offlineUuid(self.pool.allocator, row.value(0, 1));
        errdefer self.pool.allocator.free(uuid);
        return .{ .allow = try identityFromRow(self.pool.allocator, &row, 0, .cracked, uuid) };
    }

    pub fn verifyPremium(self: *Repository, canonical_nickname: []const u8, mojang_uuid: []const u8) !Decision {
        if (!validUuid(mojang_uuid)) return .deny;
        var transaction = try self.beginAuthorization();
        var committed = false;
        defer if (!committed) transaction.rollback() catch {};

        // Supported mutations lock users before dependent DML (migration 002).
        var locked = try transaction.query("SELECT u.id FROM users u JOIN applications a ON a.user_id=u.id WHERE a.minecraft_nickname_normalized=$1 FOR UPDATE OF u", &.{canonical_nickname});
        defer locked.deinit();
        if (locked.rowCount() != 1) return .deny;

        var application = try transaction.query(
            "SELECT user_id,minecraft_nickname,minecraft_nickname_normalized,client_type FROM applications WHERE user_id=$1::bigint AND minecraft_nickname_normalized=$2 AND client_type='licensed' AND status='approved'",
            &.{ locked.value(0, 0), canonical_nickname },
        );
        defer application.deinit();
        if (application.rowCount() != 1) return .deny;
        const user_id = application.value(0, 0);

        var already_bound = try transaction.query("SELECT user_id FROM game_identities WHERE licensed_mojang_uuid=$1::uuid AND user_id<>$2::bigint", &.{ mojang_uuid, user_id });
        const bound_elsewhere = already_bound.rowCount() != 0;
        already_bound.deinit();
        if (bound_elsewhere) return .deny;

        var binding = try transaction.query(
            "SELECT game_auth_bind_premium($1::bigint,$2::uuid)",
            &.{ user_id, mojang_uuid },
        );
        defer binding.deinit();
        if (binding.rowCount() != 1 or !std.mem.eql(u8, binding.value(0, 0), "t")) return .deny;
        var identity = try transaction.query("SELECT a.user_id,a.minecraft_nickname,a.minecraft_nickname_normalized,a.client_type,gi.licensed_mojang_uuid::text,gi.identity_id,gi.authentication_generation FROM applications a JOIN game_identities gi ON gi.user_id=a.user_id WHERE a.user_id=$1::bigint", &.{user_id});
        defer identity.deinit();
        if (identity.rowCount() != 1) return .deny;
        const uuid = try self.pool.allocator.dupe(u8, identity.value(0, 4));
        errdefer self.pool.allocator.free(uuid);
        const authenticated = try identityFromRow(self.pool.allocator, &identity, 0, .licensed, uuid);
        errdefer {
            self.pool.allocator.free(authenticated.nickname);
            self.pool.allocator.free(authenticated.canonical_nickname);
        }
        try transaction.commit();
        committed = true;
        return .{ .allow = authenticated };
    }

    pub fn issueLease(self: *Repository, server_id: []const u8, identity: Identity) !?Lease {
        var random: [32]u8 = undefined;
        defer std.crypto.utils.secureZero(u8, &random);
        std.crypto.random.bytes(&random);
        const token = std.fmt.bytesToHex(random, .lower);
        var hash = leaseHash(&token);
        defer std.crypto.utils.secureZero(u8, &hash);
        var user_id_buffer: [20]u8 = undefined;
        const user_id = try std.fmt.bufPrint(&user_id_buffer, "{d}", .{identity.user_id});
        var id_buffer: [20]u8 = undefined;
        var generation_buffer: [20]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buffer, "{d}", .{identity.identity_id});
        const generation = try std.fmt.bufPrint(&generation_buffer, "{d}", .{identity.authentication_generation});
        var transaction = try self.beginAuthorization();
        var committed = false;
        defer if (!committed) transaction.rollback() catch {};
        var locked = try transaction.query("SELECT id FROM users WHERE id=$1::bigint FOR UPDATE", &.{user_id});
        defer locked.deinit();
        if (locked.rowCount() != 1) return null;
        var result = try transaction.query(
            "INSERT INTO game_auth_leases (lease_hash,identity_id,server_id,client_type,authentication_generation,uuid,expires_at) SELECT $1::bytea,gi.identity_id,$3,a.client_type,gi.authentication_generation,$7::text,clock_timestamp()+INTERVAL '5 minutes' FROM applications a JOIN game_identities gi ON gi.user_id=a.user_id WHERE a.user_id=$2::bigint AND gi.identity_id=$4::bigint AND gi.authentication_generation=$5::bigint AND a.client_type=$6::minecraft_client_type AND a.status='approved' AND a.minecraft_nickname=$8 AND a.minecraft_nickname_normalized=$9 AND (a.client_type='cracked' OR gi.licensed_mojang_uuid=$7::text::uuid) RETURNING (extract(epoch FROM expires_at))::bigint",
            &.{ &hash, user_id, server_id, id, generation, @tagName(identity.client_type), identity.uuid, identity.nickname, identity.canonical_nickname },
        );
        defer result.deinit();
        if (result.rowCount() != 1) return null;
        const expires_at = try std.fmt.parseInt(i64, result.value(0, 0), 10);
        try transaction.commit();
        committed = true;
        return .{ .token = token, .expires_at = expires_at };
    }

    pub fn checkLease(self: *Repository, server_id: []const u8, token: []const u8) !LeaseDecision {
        if (token.len != 64 or !isHex(token)) return .disconnect;
        var hash = leaseHash(token);
        defer std.crypto.utils.secureZero(u8, &hash);
        var transaction = try self.beginAuthorization();
        var committed = false;
        defer if (!committed) transaction.rollback() catch {};
        var locked = try transaction.query("SELECT u.id FROM users u JOIN game_identities gi ON gi.user_id=u.id JOIN game_auth_leases l ON l.identity_id=gi.identity_id WHERE l.lease_hash=$1::bytea AND l.server_id=$2 FOR UPDATE OF u", &.{ &hash, server_id });
        defer locked.deinit();
        if (locked.rowCount() != 1) return .disconnect;
        // a fresh statement after acquiring the authorization lock sees committed mutations
        var row = try transaction.query(
            "UPDATE game_auth_leases l SET expires_at=clock_timestamp()+INTERVAL '5 minutes' FROM game_identities gi JOIN applications a ON a.user_id=gi.user_id WHERE l.identity_id=gi.identity_id AND l.lease_hash=$1::bytea AND l.server_id=$2 AND l.expires_at>clock_timestamp() AND l.client_type=a.client_type AND l.authentication_generation=gi.authentication_generation AND a.status='approved' AND (a.client_type='cracked' OR l.uuid=gi.licensed_mojang_uuid::text) RETURNING a.user_id,a.minecraft_nickname,a.minecraft_nickname_normalized,a.client_type,l.uuid,gi.identity_id,gi.authentication_generation,(extract(epoch FROM l.expires_at))::bigint",
            &.{ &hash, server_id },
        );
        defer row.deinit();
        if (row.rowCount() != 1) return .disconnect;

        const client_type = std.meta.stringToEnum(types.ClientType, row.value(0, 3)) orelse return error.InvalidClientType;
        const uuid = try self.pool.allocator.dupe(u8, row.value(0, 4));
        errdefer self.pool.allocator.free(uuid);
        const identity = try identityFromRow(self.pool.allocator, &row, 0, client_type, uuid);
        errdefer {
            self.pool.allocator.free(identity.nickname);
            self.pool.allocator.free(identity.canonical_nickname);
        }
        if (client_type == .cracked) {
            const current_uuid = try offlineUuid(self.pool.allocator, identity.nickname);
            defer self.pool.allocator.free(current_uuid);
            if (!std.mem.eql(u8, current_uuid, uuid)) {
                var cleanup = identity;
                cleanup.deinit(self.pool.allocator);
                return .disconnect;
            }
        }
        const expires_at = try std.fmt.parseInt(i64, row.value(0, 7), 10);
        try transaction.commit();
        committed = true;
        return .{ .continue_session = .{ .identity = identity, .lease = .{ .token = tokenToArray(token), .expires_at = expires_at } } };
    }

    // owner should call at most once per minute; no scheduler is configured
    pub fn cleanupExpired(self: *Repository) !void {
        var leases = try self.pool.query("DELETE FROM game_auth_leases WHERE lease_hash IN (SELECT lease_hash FROM game_auth_leases WHERE expires_at<=clock_timestamp() ORDER BY expires_at,lease_hash LIMIT 1000 FOR UPDATE SKIP LOCKED)", &.{});
        leases.deinit();
        var audits = try self.pool.query("DELETE FROM game_auth_audit WHERE id IN (SELECT id FROM game_auth_audit WHERE created_at<clock_timestamp()-INTERVAL '7 days' ORDER BY created_at,id LIMIT 1000 FOR UPDATE SKIP LOCKED)", &.{});
        audits.deinit();
    }

    fn beginAuthorization(self: *Repository) !db.Transaction {
        var transaction = try self.pool.begin();
        errdefer transaction.rollback() catch {};
        // always re-read after locking, even under repeatable-read isolation
        var isolation = try transaction.query("SET TRANSACTION ISOLATION LEVEL READ COMMITTED", &.{});
        isolation.deinit();
        return transaction;
    }

    pub fn audit(self: *Repository, server_id: []const u8, user_id: ?i64, outcome: []const u8, reason_category: []const u8) !void {
        var user_id_buffer: [20]u8 = undefined;
        const user_id_parameter = if (user_id) |value| try std.fmt.bufPrint(&user_id_buffer, "{d}", .{value}) else null;
        var result = try self.pool.query("INSERT INTO game_auth_audit (server_id,user_id,outcome,reason_category) VALUES ($1,$2::bigint,$3,$4)", &.{ server_id, user_id_parameter, outcome, reason_category });
        result.deinit();
    }

    pub fn whitelistVersion(self: *Repository) !u64 {
        var result = try self.pool.query("SELECT version FROM game_auth_whitelist_state WHERE singleton=TRUE", &.{});
        defer result.deinit();
        if (result.rowCount() != 1) return error.WhitelistStateNotFound;
        return std.fmt.parseInt(u64, result.value(0, 0), 10);
    }
};

fn identityFromRow(allocator: std.mem.Allocator, rows: *const db.Result, index: usize, client_type: types.ClientType, uuid: []u8) !Identity {
    const nickname = try allocator.dupe(u8, rows.value(index, 1));
    errdefer allocator.free(nickname);
    const canonical_nickname = try allocator.dupe(u8, rows.value(index, 2));
    errdefer allocator.free(canonical_nickname);
    return .{
        .identity_id = try std.fmt.parseInt(i64, rows.value(index, 5), 10),
        .authentication_generation = try std.fmt.parseInt(u64, rows.value(index, 6), 10),
        .user_id = try std.fmt.parseInt(i64, rows.value(index, 0), 10),
        .nickname = nickname,
        .canonical_nickname = canonical_nickname,
        .client_type = client_type,
        .uuid = uuid,
    };
}

pub fn offlineUuid(allocator: std.mem.Allocator, display_nickname: []const u8) ![]u8 {
    var name = std.ArrayList(u8).init(allocator);
    defer name.deinit();
    try name.appendSlice("OfflinePlayer:");
    try name.appendSlice(display_nickname);
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(name.items, &digest, .{});
    digest[6] = (digest[6] & 0x0f) | 0x30;
    digest[8] = (digest[8] & 0x3f) | 0x80;
    const hex = std.fmt.bytesToHex(digest, .lower);
    var uuid: [36]u8 = undefined;
    @memcpy(uuid[0..8], hex[0..8]);
    uuid[8] = '-';
    @memcpy(uuid[9..13], hex[8..12]);
    uuid[13] = '-';
    @memcpy(uuid[14..18], hex[12..16]);
    uuid[18] = '-';
    @memcpy(uuid[19..23], hex[16..20]);
    uuid[23] = '-';
    @memcpy(uuid[24..36], hex[20..32]);
    return allocator.dupe(u8, &uuid);
}

fn validUuid(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (byte != '-') return false;
        } else if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn leaseHash(token: []const u8) [66]u8 {
    var digest: [32]u8 = undefined;
    defer std.crypto.utils.secureZero(u8, &digest);
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    var encoded: [66]u8 = undefined;
    encoded[0..2].* = "\\x".*;
    encoded[2..].* = std.fmt.bytesToHex(digest, .lower);
    return encoded;
}

fn tokenToArray(token: []const u8) [64]u8 {
    var result: [64]u8 = undefined;
    @memcpy(&result, token);
    return result;
}

fn isHex(value: []const u8) bool {
    for (value) |byte| if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return false;
    return true;
}
