const std = @import("std");
const db = @import("db_pool");
const domain = @import("domain");
const repository = @import("game_auth_repository");

pub const GameAuthService = struct {
    allocator: std.mem.Allocator,
    repository: repository.Repository,
    limiter: AttemptLimiter,
    clock: *const fn () i64 = std.time.milliTimestamp,

    pub fn init(allocator: std.mem.Allocator, pool: *db.Pool) GameAuthService {
        return .{ .allocator = allocator, .repository = repository.Repository.init(pool), .limiter = AttemptLimiter.init(allocator) };
    }

    pub fn deinit(self: *GameAuthService) void {
        self.limiter.deinit();
    }

    pub fn admitServer(self: *GameAuthService, server_id: []const u8) !void {
        if (!try self.limiter.server(server_id, self.clock())) return error.RateLimited;
    }

    pub fn admitNickname(self: *GameAuthService, server_id: []const u8, name: []const u8) !void {
        if (!try self.limiter.nickname(server_id, name, self.clock())) return error.RateLimited;
    }

    pub fn whitelist(self: *GameAuthService, cursor: ?u64) ![]u8 {
        var snapshot = try self.repository.whitelistSnapshot(cursor);
        defer snapshot.deinit(self.allocator);
        if (snapshot.unchanged) return stringify(self.allocator, .{ .outcome = "unchanged", .whitelist_version = snapshot.version });
        const Item = struct { nickname: []const u8, client_type: []const u8, uuid: []const u8 };
        var identities = try std.ArrayList(Item).initCapacity(self.allocator, snapshot.identities.len);
        defer identities.deinit();
        for (snapshot.identities) |identity| try identities.append(.{ .nickname = identity.nickname, .client_type = @tagName(identity.client_type), .uuid = identity.uuid });
        return stringify(self.allocator, .{ .outcome = "snapshot", .whitelist_version = snapshot.version, .identities = identities.items });
    }

    pub fn nicknamePolicy(self: *GameAuthService, name: []const u8) ![]u8 {
        const nickname = domain.nickname.validateNickname(name) catch return stringify(self.allocator, .{ .outcome = "denied" });
        const policy = try self.repository.nicknamePolicy(nickname.canonical());
        return stringify(self.allocator, .{ .outcome = @tagName(policy) });
    }

    pub fn crackedLogin(self: *GameAuthService, server_id: []const u8, body: []const u8) ![]u8 {
        var wiping = WipingAllocator{ .backing = self.allocator };
        var arena = std.heap.ArenaAllocator.init(.{ .ptr = &wiping, .vtable = &WipingAllocator.vtable });
        defer arena.deinit();
        const parsed = try parseObject(arena.allocator(), body, &.{ "nickname", "password" });
        const nickname = domain.nickname.validateNickname(try requiredText(parsed.value.object, "nickname")) catch return self.deny(server_id, "invalid_nickname");
        try self.admitNickname(server_id, nickname.canonical());
        const password: []u8 = @constCast(try requiredText(parsed.value.object, "password"));
        defer std.crypto.utils.secureZero(u8, password);
        var decision = try self.repository.authenticateCracked(nickname.canonical(), password);
        std.crypto.utils.secureZero(u8, password);
        if (decision == .deny) {
            return self.deny(server_id, "cracked_login");
        }
        return self.respondToLogin(server_id, &decision, "cracked_login");
    }

    pub fn premiumVerified(self: *GameAuthService, server_id: []const u8, body: []const u8) ![]u8 {
        var wiping = WipingAllocator{ .backing = self.allocator };
        var arena = std.heap.ArenaAllocator.init(.{ .ptr = &wiping, .vtable = &WipingAllocator.vtable });
        defer arena.deinit();
        const parsed = try parseObject(arena.allocator(), body, &.{ "nickname", "mojang_uuid" });
        const nickname = domain.nickname.validateNickname(try requiredText(parsed.value.object, "nickname")) catch return self.deny(server_id, "invalid_nickname");
        try self.admitNickname(server_id, nickname.canonical());
        const mojang_uuid = try requiredText(parsed.value.object, "mojang_uuid");
        var decision = try self.repository.verifyPremium(nickname.canonical(), mojang_uuid);
        return self.respondToLogin(server_id, &decision, "premium_verified");
    }

    pub fn sessionCheck(self: *GameAuthService, server_id: []const u8, body: []const u8) ![]u8 {
        var wiping = WipingAllocator{ .backing = self.allocator };
        var arena = std.heap.ArenaAllocator.init(.{ .ptr = &wiping, .vtable = &WipingAllocator.vtable });
        defer arena.deinit();
        const parsed = try parseObject(arena.allocator(), body, &.{"lease"});
        const lease = try requiredText(parsed.value.object, "lease");
        var decision = try self.repository.checkLease(server_id, lease);
        switch (decision) {
            .disconnect => return self.disconnect(server_id, "invalid_or_expired_lease"),
            .continue_session => |*allowed| {
                defer std.crypto.utils.secureZero(u8, &allowed.lease.token);
                defer allowed.identity.deinit(self.allocator);
                if (allowed.identity.user_id <= 0) return error.InvalidUserId;
                try self.repository.audit(server_id, allowed.identity.user_id, "continue", "lease_valid");
                const version = try self.repository.whitelistVersion();
                return stringify(self.allocator, .{ .outcome = "continue", .uuid = allowed.identity.uuid, .lease = @as([]const u8, &allowed.lease.token), .expires_at = allowed.lease.expires_at, .whitelist_version = version, .user_id = allowed.identity.user_id });
            },
        }
    }

    fn respondToLogin(self: *GameAuthService, server_id: []const u8, decision: *repository.Decision, reason_category: []const u8) ![]u8 {
        switch (decision.*) {
            .deny => return self.deny(server_id, reason_category),
            .allow => |*identity| {
                defer identity.deinit(self.allocator);
                if (identity.user_id <= 0) return error.InvalidUserId;
                var lease = (try self.repository.issueLease(server_id, identity.*)) orelse return self.deny(server_id, reason_category);
                defer std.crypto.utils.secureZero(u8, &lease.token);
                try self.repository.audit(server_id, identity.user_id, "allow", reason_category);
                const version = try self.repository.whitelistVersion();
                return stringify(self.allocator, .{ .outcome = "allow", .uuid = identity.uuid, .lease = @as([]const u8, &lease.token), .expires_at = lease.expires_at, .whitelist_version = version, .user_id = identity.user_id });
            },
        }
    }

    fn deny(self: *GameAuthService, server_id: []const u8, reason_category: []const u8) ![]u8 {
        try self.repository.audit(server_id, null, "deny", reason_category);
        return stringify(self.allocator, .{ .outcome = "deny", .whitelist_version = try self.repository.whitelistVersion() });
    }

    fn disconnect(self: *GameAuthService, server_id: []const u8, reason_category: []const u8) ![]u8 {
        try self.repository.audit(server_id, null, "disconnect", reason_category);
        return stringify(self.allocator, .{ .outcome = "disconnect", .whitelist_version = try self.repository.whitelistVersion() });
    }
};

fn stringify(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    // returned bytes belong to the backing allocator and are wiped by the route
    // the local adapter handles temporary allocations without escaping
    var wiping = WipingAllocator{ .backing = allocator };
    return std.json.stringifyAlloc(.{ .ptr = &wiping, .vtable = &WipingAllocator.vtable }, value, .{});
}

// fixed one-minute limits: 120/server and 5/name, counting all attempts
// check aggregate limits before allocation and audit
// never evict active windows when capacity is reached
pub const AttemptLimiter = struct {
    const Window = struct { started: i64, attempts: u16 };
    const Map = std.AutoHashMap([32]u8, Window);
    mutex: std.Thread.Mutex = .{},
    names: Map,
    servers: Map,
    pub fn init(a: std.mem.Allocator) AttemptLimiter {
        return .{ .names = Map.init(a), .servers = Map.init(a) };
    }
    pub fn deinit(self: *@This()) void {
        self.names.deinit();
        self.servers.deinit();
    }
    pub fn server(self: *@This(), id: []const u8, now: i64) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return take(&self.servers, crackedAttemptKey(id, ""), now, 64, 120);
    }
    pub fn nickname(self: *@This(), id: []const u8, name: []const u8, now: i64) !bool {
        var normalized: [64]u8 = undefined;
        if (name.len > normalized.len) return false;
        for (name, 0..) |byte, i| normalized[i] = std.ascii.toLower(byte);
        self.mutex.lock();
        defer self.mutex.unlock();
        return take(&self.names, crackedAttemptKey(id, normalized[0..name.len]), now, 4096, 5);
    }
    fn take(map: *Map, key: [32]u8, now: i64, capacity: usize, threshold: u16) !bool {
        if (map.getPtr(key)) |window| {
            if (now >= window.started and now - window.started >= 60000) window.* = .{ .started = now, .attempts = 0 };
            if (window.attempts >= threshold) return false;
            window.attempts += 1;
            return true;
        }
        if (map.count() >= capacity) {
            var iterator = map.iterator();
            var expired: ?[32]u8 = null;
            while (iterator.next()) |entry| {
                if (now >= entry.value_ptr.started and now - entry.value_ptr.started >= 60000) {
                    expired = entry.key_ptr.*;
                    break;
                }
            }
            if (expired) |old| {
                _ = map.remove(old);
            } else return false;
        }
        try map.put(key, .{ .started = now, .attempts = 1 });
        return true;
    }
};

fn crackedAttemptKey(server_id: []const u8, canonical_nickname: []const u8) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(server_id);
    hasher.update(&[_]u8{0});
    hasher.update(canonical_nickname);
    var result: [32]u8 = undefined;
    hasher.final(&result);
    return result;
}

fn parseObject(allocator: std.mem.Allocator, body: []const u8, allowed_fields: []const []const u8) !std.json.Parsed(std.json.Value) {
    // zig 0.13 overwrites duplicate json keys regardless of parse options.
    // validate the typed schema first using the same wiping arena.
    if (std.mem.eql(u8, allowed_fields[0], "lease")) {
        try validateSchema(struct { lease: []const u8 }, allocator, body);
    } else if (std.mem.eql(u8, allowed_fields[1], "password")) {
        try validateSchema(struct { nickname: []const u8, password: []const u8 }, allocator, body);
    } else {
        try validateSchema(struct { nickname: []const u8, mojang_uuid: []const u8 }, allocator, body);
    }
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidJson;
    if (parsed.value != .object) return error.InvalidJson;
    if (parsed.value.object.count() != allowed_fields.len) return error.InvalidJson;
    for (allowed_fields) |field| _ = try requiredText(parsed.value.object, field);
    var fields = parsed.value.object.iterator();
    while (fields.next()) |entry| {
        var permitted = false;
        for (allowed_fields) |allowed| {
            if (std.mem.eql(u8, entry.key_ptr.*, allowed)) {
                permitted = true;
                break;
            }
        }
        if (!permitted) return error.InvalidJson;
    }
    return parsed;
}

fn validateSchema(comptime T: type, allocator: std.mem.Allocator, body: []const u8) !void {
    const parsed = std.json.parseFromSlice(T, allocator, body, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error", .ignore_unknown_fields = false }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidJson;
    parsed.deinit();
}

fn requiredText(object: std.json.ObjectMap, field: []const u8) ![]const u8 {
    const value = object.get(field) orelse return error.InvalidJson;
    if (value != .string or value.string.len == 0 or !std.unicode.utf8ValidateSlice(value.string) or std.mem.indexOfScalar(u8, value.string, 0) != null) return error.InvalidJson;
    return value.string;
}

pub const WipingAllocator = struct {
    backing: std.mem.Allocator,

    fn alloc(context: *anyopaque, len: usize, alignment: u8, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.backing.rawAlloc(len, alignment, ra);
    }

    fn resize(_: *anyopaque, _: []u8, _: u8, _: usize, _: usize) bool {
        return false;
    }

    fn free(context: *anyopaque, buffer: []u8, alignment: u8, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        std.crypto.utils.secureZero(u8, buffer);
        self.backing.rawFree(buffer, alignment, ra);
    }

    pub const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .free = free };
};
