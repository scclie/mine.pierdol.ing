const std = @import("std");
const config = @import("config");
const users = @import("users");
const types = @import("domain").types;
const db = @import("db_pool");

pub const Request = struct {
    session_token: []const u8,
    csrf_token: ?[]const u8,
};

pub const IssuedSession = struct {
    session_token: [64]u8,
    csrf_token: [64]u8,

    pub fn deinit(self: *IssuedSession, _: std.mem.Allocator) void {
        @memset(self.session_token[0..], 0);
        @memset(self.csrf_token[0..], 0);
    }
};

pub const AuthenticatedActor = struct {
    user_id: i64,
    role: types.Role,
    csrf_token_hash: [32]u8,
};

pub const AuthService = struct {
    allocator: std.mem.Allocator,
    users: users.UserRepository,
    configuration: *const config.Config,

    pub fn init(allocator: std.mem.Allocator, pool: *db.Pool, configuration: *const config.Config) AuthService {
        return .{
            .allocator = allocator,
            .users = users.UserRepository.init(pool),
            .configuration = configuration,
        };
    }

    pub fn createSession(self: *AuthService, user_id: i64) !IssuedSession {
        var session_token_bytes: [32]u8 = undefined;
        std.crypto.random.bytes(&session_token_bytes);
        defer @memset(session_token_bytes[0..], 0);
        var csrf_token_bytes: [32]u8 = undefined;
        std.crypto.random.bytes(&csrf_token_bytes);
        defer @memset(csrf_token_bytes[0..], 0);
        var session_id_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&session_id_bytes);
        defer @memset(session_id_bytes[0..], 0);
        session_id_bytes[6] = (session_id_bytes[6] & 0x0f) | 0x40;
        session_id_bytes[8] = (session_id_bytes[8] & 0x3f) | 0x80;

        var issued = IssuedSession{
            .session_token = undefined,
            .csrf_token = undefined,
        };
        errdefer issued.deinit(self.allocator);
        encodeHex(&session_token_bytes, &issued.session_token);
        encodeHex(&csrf_token_bytes, &issued.csrf_token);

        var token_hash = hashParameter(&issued.session_token);
        defer @memset(token_hash[0..], 0);
        var csrf_token_hash = hashParameter(&issued.csrf_token);
        defer @memset(csrf_token_hash[0..], 0);
        var session_id: [36]u8 = undefined;
        encodeUuid(&session_id_bytes, &session_id);
        try self.users.createSession(user_id, &session_id, &token_hash, &csrf_token_hash);
        return issued;
    }

    pub fn authenticate(self: *AuthService, request: Request) !AuthenticatedActor {
        var token_hash = hashParameter(request.session_token);
        defer @memset(token_hash[0..], 0);
        var session = try self.users.findActiveSession(self.allocator, &token_hash);
        defer session.deinit(self.allocator);
        return .{
            .user_id = session.user_id,
            .role = roleForDiscordId(self.configuration, session.discord_id),
            .csrf_token_hash = session.csrf_token_hash,
        };
    }

    pub fn revokeUserSessions(self: *AuthService, user_id: i64) !void {
        try self.users.revokeSessions(user_id);
    }

    pub fn requireCsrf(_: *AuthService, request: Request, actor: AuthenticatedActor) !void {
        const csrf_token = request.csrf_token orelse return error.CsrfTokenRequired;
        var csrf_token_hash = hashToken(csrf_token);
        defer @memset(csrf_token_hash[0..], 0);
        if (!timingSafeEql(&csrf_token_hash, &actor.csrf_token_hash)) return error.CsrfTokenInvalid;
    }
};

pub fn roleForDiscordId(configuration: *const config.Config, discord_id: []const u8) types.Role {
    const numeric_discord_id = std.fmt.parseInt(u64, discord_id, 10) catch return .player;
    if (configuration.administrator_discord_ids.contains(numeric_discord_id)) return .administrator;
    if (configuration.moderator_discord_ids.contains(numeric_discord_id)) return .moderator;
    return .player;
}

fn hashParameter(token: []const u8) [66]u8 {
    const hash = hashToken(token);
    var result: [66]u8 = undefined;
    result[0] = '\\';
    result[1] = 'x';
    encodeHex(&hash, result[2..]);
    return result;
}

fn hashToken(token: []const u8) [32]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &hash, .{});
    return hash;
}

fn timingSafeEql(left: *const [32]u8, right: *const [32]u8) bool {
    var difference: u8 = 0;
    for (left, right) |left_byte, right_byte| difference |= left_byte ^ right_byte;
    return difference == 0;
}

fn encodeHex(source: []const u8, destination: []u8) void {
    const alphabet = "0123456789abcdef";
    for (source, 0..) |byte, index| {
        destination[index * 2] = alphabet[byte >> 4];
        destination[index * 2 + 1] = alphabet[byte & 0x0f];
    }
}

fn encodeUuid(source: *const [16]u8, destination: *[36]u8) void {
    var hex: [32]u8 = undefined;
    encodeHex(source, &hex);
    var source_index: usize = 0;
    var destination_index: usize = 0;
    while (destination_index < destination.len) : (destination_index += 1) {
        if (destination_index == 8 or destination_index == 13 or destination_index == 18 or destination_index == 23) {
            destination[destination_index] = '-';
        } else {
            destination[destination_index] = hex[source_index];
            source_index += 1;
        }
    }
}
