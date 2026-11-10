const std = @import("std");
const db = @import("db_pool");
const domain = @import("domain");
const repository = @import("applications_repository");
const auth = @import("auth");
const types = domain.types;

pub const Mutation = repository.Mutation;

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
        return std.json.stringifyAlloc(self.allocator, .{
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
        }, .{});
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
};

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
