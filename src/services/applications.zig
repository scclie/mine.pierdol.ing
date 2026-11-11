const std = @import("std");
const db = @import("db_pool");
const domain = @import("domain");
const repository = @import("applications_repository");
const auth = @import("auth");
const types = domain.types;

pub const Mutation = repository.Mutation;
pub const Queue = repository.Queue;
pub const AdminMutation = repository.AdminMutation;

pub const ApplicationService = struct {
    allocator: std.mem.Allocator,
    repository: repository.ApplicationRepository,
    deny_list: domain.password.DenyList,

    pub fn init(allocator: std.mem.Allocator, pool: *db.Pool) !ApplicationService {
        return .{ .allocator = allocator, .repository = repository.ApplicationRepository.init(pool), .deny_list = try domain.password.loadDefaultDenyList(allocator) };
    }

    pub fn deinit(self: *ApplicationService) void {
        self.deny_list.deinit();
    }

    pub fn account(self: *ApplicationService, actor: auth.AuthenticatedActor, session_token: []const u8) ![]u8 {
        var result = try self.repository.account(actor.user_id);
        defer result.deinit();
        if (result.rowCount() != 1) return error.SessionNotFound;
        const status = parseStatus(&result);
        const client_type = parseClientType(&result);
        const Application = struct {
            minecraft_nickname: []const u8,
            client_type: types.ClientType,
            status: types.ApplicationStatus,
            decision_reason: ?[]const u8,
        };
        var token = randomToken();
        defer std.crypto.utils.secureZero(u8, &token);
        var token_hash = hashParameter(session_token);
        defer std.crypto.utils.secureZero(u8, &token_hash);
        var csrf_hash = hashParameter(&token);
        defer std.crypto.utils.secureZero(u8, &csrf_hash);
        try self.repository.refreshCsrf(actor.user_id, &token_hash, &csrf_hash);
        const payload = .{
            .user = .{ .id = actor.user_id, .discord_id = result.value(0, 1), .display_name = result.value(0, 2), .role = actor.role },
            .application = if (status) |value| @as(?Application, .{
                .minecraft_nickname = result.value(0, 3),
                .client_type = client_type.?,
                .status = value,
                .decision_reason = if (std.mem.eql(u8, result.value(0, 7), "t")) null else result.value(0, 6),
            }) else null,
            .actions = .{
                .can_submit = allowed(actor, .create, status, client_type),
                .can_resubmit = allowed(actor, .resubmit, status, client_type),
                .can_change_password = allowed(actor, .password, status, client_type),
            },
            .csrf_token = @as([]const u8, &token),
        };
        if (status == .approved and client_type == .cracked and std.mem.eql(u8, result.value(0, 8), "t")) return std.json.stringifyAlloc(self.allocator, .{ .user = payload.user, .application = payload.application, .actions = payload.actions, .csrf_token = payload.csrf_token, .password_setup_required = true }, .{});
        return std.json.stringifyAlloc(self.allocator, payload, .{});
    }

    pub fn mutate(self: *ApplicationService, actor: auth.AuthenticatedActor, request: auth.Request, mutation: Mutation, body: []const u8) !void {
        var current = try self.repository.account(actor.user_id);
        defer current.deinit();
        if (current.rowCount() != 1) return error.SessionNotFound;
        try repository.requireAction(.{ .user_id = actor.user_id, .role = actor.role }, mutation, parseStatus(&current), parseClientType(&current));

        // wipe all parsed data, including password copies
        var wiping = WipingAllocator{ .backing = self.allocator };
        var arena = std.heap.ArenaAllocator.init(.{ .ptr = &wiping, .vtable = &WipingAllocator.vtable });
        defer arena.deinit();
        const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), body, .{ .allocate = .alloc_always }) catch return error.InvalidJson;
        if (parsed.value != .object) return error.InvalidJson;
        const object = parsed.value.object;
        var input: ?repository.AccountInput = null;
        var hash: ?[]u8 = null;
        defer if (hash) |value| {
            std.crypto.utils.secureZero(u8, value);
            self.allocator.free(value);
        };
        if (mutation == .password) {
            const password = try passwordField(object, false);
            hash = try self.hashPassword(password orelse return error.PasswordRequired);
        } else {
            const nickname = try textField(object, "minecraft_nickname");
            const canonical = domain.nickname.validateNickname(nickname) catch return error.InvalidMinecraftNickname;
            const raw_client = try textField(object, "client_type");
            const client_type = std.meta.stringToEnum(types.ClientType, raw_client) orelse return error.InvalidClientType;
            const about_me = try textField(object, "about_me");
            if (about_me.len > 2000) return error.AboutMeTooLong;
            const discovery_source = try textField(object, "discovery_source");
            if (discovery_source.len > 300) return error.DiscoverySourceTooLong;
            const password = try passwordField(object, client_type == .licensed);
            if (client_type == .cracked) hash = try self.hashPassword(password orelse return error.PasswordRequiredForCracked);
            input = .{ .nickname = canonical, .client_type = client_type, .about_me = about_me, .discovery_source = discovery_source, .password_hash = hash };
        }
        var unused_token = randomToken();
        defer std.crypto.utils.secureZero(u8, &unused_token);
        var proof = repository.SessionProof{
            .token_hash = hashParameter(request.session_token),
            .csrf_hash = hashParameter(request.csrf_token orelse return error.CsrfTokenRequired),
            .next_csrf_hash = hashParameter(&unused_token),
        };
        defer std.crypto.utils.secureZero(u8, std.mem.asBytes(&proof));
        try self.repository.mutateAccount(.{ .user_id = actor.user_id, .role = actor.role }, mutation, input, hash, proof);
    }

    fn hashPassword(self: *ApplicationService, password: []const u8) ![]u8 {
        try domain.password.validatePassword(password, self.deny_list);
        return domain.password.hashPassword(self.allocator, password);
    }

    pub fn queue(self: *ApplicationService, options: Queue) ![]u8 {
        var result = try self.repository.queue(options);
        defer result.deinit();
        const Item = struct { user_id: i64, discord_id: []const u8, display_name: []const u8, minecraft_nickname: []const u8, client_type: []const u8, status: []const u8, submitted_at: []const u8 };
        var items = std.ArrayList(Item).init(self.allocator);
        defer items.deinit();
        const count = @min(result.rowCount(), options.limit);
        for (0..count) |i| try items.append(.{
            .user_id = try std.fmt.parseInt(i64, result.value(i, 0), 10),
            .discord_id = result.value(i, 1),
            .display_name = result.value(i, 2),
            .minecraft_nickname = result.value(i, 3),
            .client_type = result.value(i, 4),
            .status = result.value(i, 5),
            .submitted_at = result.value(i, 6),
        });
        var cursor: [32]u8 = undefined;
        if (result.rowCount() > count) {
            var bytes: [16]u8 = undefined;
            std.mem.writeInt(i64, bytes[0..8], try std.fmt.parseInt(i64, result.value(count - 1, 7), 10), .big);
            std.mem.writeInt(i64, bytes[8..16], try std.fmt.parseInt(i64, result.value(count - 1, 0), 10), .big);
            cursor = std.fmt.bytesToHex(bytes, .lower);
        }
        return std.json.stringifyAlloc(self.allocator, .{ .applications = items.items, .next_cursor = if (result.rowCount() > count) @as(?[]const u8, &cursor) else null }, .{});
    }

    pub fn card(self: *ApplicationService, user_id: i64) ![]u8 {
        var result = try self.repository.card(user_id);
        defer result.deinit();
        if (result.rowCount() != 1) return error.UserNotFound;
        const status = std.meta.stringToEnum(types.ApplicationStatus, result.value(0, 7));
        const Application = struct { minecraft_nickname: []const u8, client_type: []const u8, status: []const u8, about_me: []const u8, discovery_source: []const u8, decision_reason: ?[]const u8, submitted_at: []const u8, decided_at: ?[]const u8, decided_by_user_id: ?i64 };
        return std.json.stringifyAlloc(self.allocator, .{
            .user = .{ .id = user_id, .discord_id = result.value(0, 1), .discord_username = result.value(0, 2), .discord_global_name = nullable(result.value(0, 3)), .discord_avatar_hash = nullable(result.value(0, 4)) },
            .application = if (status != null) @as(?Application, .{ .minecraft_nickname = result.value(0, 5), .client_type = result.value(0, 6), .status = result.value(0, 7), .about_me = result.value(0, 8), .discovery_source = result.value(0, 9), .decision_reason = if (std.mem.eql(u8, result.value(0, 11), "t")) null else result.value(0, 10), .submitted_at = result.value(0, 12), .decided_at = nullable(result.value(0, 13)), .decided_by_user_id = if (nullable(result.value(0, 14))) |value| try std.fmt.parseInt(i64, value, 10) else null }) else null,
            .password_setup_required = status == .approved and std.mem.eql(u8, result.value(0, 6), "cracked") and std.mem.eql(u8, result.value(0, 15), "t"),
        }, .{});
    }

    pub fn mutateAdmin(self: *ApplicationService, service: *auth.AuthService, actor: auth.AuthenticatedActor, request: auth.Request, user_id: i64, mutation: AdminMutation, body: []const u8) !void {
        var wiping = WipingAllocator{ .backing = self.allocator };
        var arena = std.heap.ArenaAllocator.init(.{ .ptr = &wiping, .vtable = &WipingAllocator.vtable });
        defer arena.deinit();
        const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), body, .{ .allocate = .alloc_always }) catch return error.InvalidJson;
        if (parsed.value != .object) return error.InvalidJson;
        const object = parsed.value.object;
        var fields = object.iterator();
        while (fields.next()) |entry| {
            const key = entry.key_ptr.*;
            const allowed_field = switch (mutation) {
                .approve => false,
                .reject => std.mem.eql(u8, key, "kind") or std.mem.eql(u8, key, "reason"),
                .edit => std.mem.eql(u8, key, "minecraft_nickname") or std.mem.eql(u8, key, "discord_id") or std.mem.eql(u8, key, "client_type") or std.mem.eql(u8, key, "status") or std.mem.eql(u8, key, "reason"),
            };
            if (!allowed_field) return error.InvalidPatchField;
        }
        var patch = repository.AdminPatch{};
        if (object.get("reason")) |value| {
            if (value != .string or !validText(value.string)) return error.InvalidReason;
            const reason = std.mem.trim(u8, value.string, " \t\r\n");
            if (reason.len == 0) return error.ReasonRequired;
            if (reason.len > 2000) return error.ReasonTooLong;
            patch.reason = reason;
        }
        switch (mutation) {
            .approve => patch.status = .approved,
            .reject => {
                const kind = try adminField(object, "kind", error.InvalidRejectionKind);
                patch.status = if (std.mem.eql(u8, kind, "retryable")) .rejected_retryable else if (std.mem.eql(u8, kind, "final")) .rejected_final else return error.InvalidRejectionKind;
                if (patch.reason == null) return error.ReasonRequired;
            },
            .edit => {
                if (object.contains("minecraft_nickname")) patch.nickname = domain.nickname.validateNickname(try adminField(object, "minecraft_nickname", error.InvalidMinecraftNickname)) catch return error.InvalidMinecraftNickname;
                if (object.contains("discord_id")) {
                    const value = try adminField(object, "discord_id", error.InvalidDiscordId);
                    if (value.len == 0 or value.len > 20 or value[0] == '0') return error.InvalidDiscordId;
                    for (value) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidDiscordId;
                    _ = std.fmt.parseInt(u64, value, 10) catch return error.InvalidDiscordId;
                    patch.discord_id = value;
                }
                if (object.contains("client_type")) patch.client_type = std.meta.stringToEnum(types.ClientType, try adminField(object, "client_type", error.InvalidClientType)) orelse return error.InvalidClientType;
                if (object.contains("status")) patch.status = std.meta.stringToEnum(types.ApplicationStatus, try adminField(object, "status", error.InvalidStatus)) orelse return error.InvalidStatus;
                if (patch.nickname == null and patch.discord_id == null and patch.client_type == null and patch.status == null) return error.EmptyPatch;
                if ((patch.status == .banned or patch.status == .rejected_retryable or patch.status == .rejected_final) and patch.reason == null) return error.ReasonRequired;
            },
        }
        var unused = randomToken();
        defer std.crypto.utils.secureZero(u8, &unused);
        var proof = repository.SessionProof{ .token_hash = hashParameter(request.session_token), .csrf_hash = hashParameter(request.csrf_token orelse return error.CsrfTokenRequired), .next_csrf_hash = hashParameter(&unused) };
        defer std.crypto.utils.secureZero(u8, std.mem.asBytes(&proof));
        try self.repository.mutateAdmin(service, actor.user_id, user_id, mutation, patch, proof);
    }
};

fn nullable(value: []const u8) ?[]const u8 {
    return if (value.len == 0) null else value;
}
fn validText(value: []const u8) bool {
    return std.unicode.utf8ValidateSlice(value) and std.mem.indexOfScalar(u8, value, 0) == null;
}
fn adminField(object: std.json.ObjectMap, field: []const u8, invalid: anyerror) ![]const u8 {
    const value = object.get(field) orelse return invalid;
    if (value != .string or !validText(value.string)) return invalid;
    return std.mem.trim(u8, value.string, " \t\r\n");
}

fn parseStatus(result: *const db.Result) ?types.ApplicationStatus {
    return std.meta.stringToEnum(types.ApplicationStatus, result.value(0, 5));
}

fn parseClientType(result: *const db.Result) ?types.ClientType {
    return std.meta.stringToEnum(types.ClientType, result.value(0, 4));
}

fn allowed(actor: auth.AuthenticatedActor, mutation: Mutation, status: ?types.ApplicationStatus, client_type: ?types.ClientType) bool {
    repository.requireAction(.{ .user_id = actor.user_id, .role = actor.role }, mutation, status, client_type) catch return false;
    return true;
}

fn textField(object: std.json.ObjectMap, comptime field: []const u8) ![]const u8 {
    const required = comptime if (std.mem.eql(u8, field, "minecraft_nickname")) error.MinecraftNicknameRequired else if (std.mem.eql(u8, field, "about_me")) error.AboutMeRequired else if (std.mem.eql(u8, field, "discovery_source")) error.DiscoverySourceRequired else error.InvalidClientType;
    const invalid = comptime if (std.mem.eql(u8, field, "minecraft_nickname")) error.InvalidMinecraftNickname else if (std.mem.eql(u8, field, "about_me")) error.InvalidAboutMe else if (std.mem.eql(u8, field, "discovery_source")) error.InvalidDiscoverySource else error.InvalidClientType;
    const value = object.get(field) orelse return required;
    if (value != .string) return invalid;
    if (!std.unicode.utf8ValidateSlice(value.string) or std.mem.indexOfScalar(u8, value.string, 0) != null) return invalid;
    const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
    if (trimmed.len == 0) return required;
    return trimmed;
}

fn passwordField(object: std.json.ObjectMap, licensed: bool) !?[]const u8 {
    const value = object.get("password") orelse return null;
    if (licensed) return error.PasswordNotAllowedForLicensed;
    if (value != .string) return error.InvalidPassword;
    if (!std.unicode.utf8ValidateSlice(value.string) or std.mem.indexOfScalar(u8, value.string, 0) != null) return error.InvalidPassword;
    if (std.mem.trim(u8, value.string, " \t\r\n").len == 0) return null;
    return value.string;
}

fn randomToken() [64]u8 {
    var bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    defer std.crypto.utils.secureZero(u8, &bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

fn hashParameter(token: []const u8) [66]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &hash, .{});
    defer std.crypto.utils.secureZero(u8, &hash);
    var result: [66]u8 = undefined;
    result[0..2].* = "\\x".*;
    result[2..].* = std.fmt.bytesToHex(hash, .lower);
    return result;
}

const WipingAllocator = struct {
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

    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .free = free };
};
