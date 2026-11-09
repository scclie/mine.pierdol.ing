const std = @import("std");
const config = @import("config");
const db = @import("db_pool");

pub const DiscordIdentity = struct {
    id: []const u8,
    username: []const u8,
    global_name: ?[]const u8,
    avatar: ?[]const u8,
};

pub const AuthorizationRedirect = struct {
    location: []u8,
    state: []u8,

    pub fn deinit(self: *AuthorizationRedirect, allocator: std.mem.Allocator) void {
        @memset(self.location, 0);
        allocator.free(self.location);
        @memset(self.state, 0);
        allocator.free(self.state);
    }
};

pub const Endpoint = struct {
    authorization_endpoint: []const u8,
    context: *anyopaque,
    exchange: *const fn (context: *anyopaque, code: []const u8, verifier: []const u8) anyerror![]const u8,
    identity: *const fn (context: *anyopaque, access_token: []const u8) anyerror!DiscordIdentity,
    release_access_token: ?*const fn (context: *anyopaque, access_token: []const u8) void = null,
    release_identity: ?*const fn (context: *anyopaque, identity: DiscordIdentity) void = null,
};

pub const CompletedCallback = struct {
    identity: DiscordIdentity,
    return_path: []u8,
    endpoint: Endpoint,

    pub fn deinit(self: *CompletedCallback, allocator: std.mem.Allocator) void {
        if (self.endpoint.release_identity) |release_identity| release_identity(self.endpoint.context, self.identity);
        allocator.free(self.return_path);
    }
};

pub const DiscordService = struct {
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    configuration: *const config.Config,
    endpoint: Endpoint,
    test_urls: if (@import("builtin").is_test) ?struct { token: []const u8, identity: []const u8 } else void = if (@import("builtin").is_test) null else {},

    pub fn init(allocator: std.mem.Allocator, pool: *db.Pool, configuration: *const config.Config, endpoint: Endpoint) DiscordService {
        return .{ .allocator = allocator, .pool = pool, .configuration = configuration, .endpoint = endpoint };
    }

    pub fn initProduction(allocator: std.mem.Allocator, pool: *db.Pool, configuration: *const config.Config) DiscordService {
        return init(allocator, pool, configuration, .{
            .authorization_endpoint = "https://discord.com/api/oauth2/authorize",
            .context = @constCast(configuration),
            .exchange = exchangeProduction,
            .identity = fetchProductionIdentity,
            .release_access_token = releaseAllocatedToken,
            .release_identity = releaseAllocatedIdentity,
        });
    }

    pub fn initProductionForTest(allocator: std.mem.Allocator, pool: *db.Pool, configuration: *const config.Config, token_url: []const u8, identity_url: []const u8) DiscordService {
        if (!@import("builtin").is_test) @compileError("test-only provider endpoints");
        var service = initProduction(allocator, pool, configuration);
        service.test_urls = .{ .token = token_url, .identity = identity_url };
        return service;
    }

    pub fn beginLogin(self: *DiscordService, requested_return_path: ?[]const u8) !AuthorizationRedirect {
        const return_path = sanitizeReturnPath(requested_return_path);
        var state_bytes: [32]u8 = undefined;
        std.crypto.random.bytes(&state_bytes);
        defer @memset(&state_bytes, 0);
        var verifier_bytes: [32]u8 = undefined;
        std.crypto.random.bytes(&verifier_bytes);
        defer @memset(&verifier_bytes, 0);

        var state: [43]u8 = undefined;
        defer @memset(&state, 0);
        encodeBase64Url(&state_bytes, &state);
        var verifier: [43]u8 = undefined;
        defer @memset(&verifier, 0);
        encodeBase64Url(&verifier_bytes, &verifier);
        var state_hash = sha256(&state);
        defer @memset(&state_hash, 0);
        var challenge_hash = sha256(&verifier);
        defer @memset(&challenge_hash, 0);
        var challenge: [43]u8 = undefined;
        defer @memset(&challenge, 0);
        encodeBase64Url(&challenge_hash, &challenge);
        var state_parameter: [66]u8 = undefined;
        defer @memset(&state_parameter, 0);
        encodeByteaParameter(&state_hash, &state_parameter);

        var insert = try self.pool.query(
            "INSERT INTO oauth_states (state_hash, pkce_verifier, return_path, expires_at) VALUES ($1::bytea, $2, $3, now() + INTERVAL '10 minutes')",
            &.{ &state_parameter, &verifier, return_path },
        );
        insert.deinit();

        const encoded_client_id = try formEncode(self.allocator, self.configuration.discord_client_id);
        defer self.allocator.free(encoded_client_id);
        const encoded_redirect_uri = try formEncode(self.allocator, self.configuration.discord_redirect_uri);
        defer self.allocator.free(encoded_redirect_uri);
        const location = try std.fmt.allocPrint(self.allocator, "{s}?response_type=code&client_id={s}&redirect_uri={s}&scope=identify&state={s}&code_challenge={s}&code_challenge_method=S256", .{
            self.endpoint.authorization_endpoint,
            encoded_client_id,
            encoded_redirect_uri,
            &state,
            &challenge,
        });
        errdefer {
            @memset(location, 0);
            self.allocator.free(location);
        }
        return .{ .location = location, .state = try self.allocator.dupe(u8, &state) };
    }

    pub fn completeCallback(self: *DiscordService, code: []const u8, state: []const u8) !CompletedCallback {
        if (code.len == 0 or state.len == 0) return error.OauthStateInvalid;
        var state_hash = sha256(state);
        defer @memset(&state_hash, 0);
        var state_parameter: [66]u8 = undefined;
        defer @memset(&state_parameter, 0);
        encodeByteaParameter(&state_hash, &state_parameter);

        var transaction = try self.pool.begin();
        var committed = false;
        errdefer if (!committed) transaction.rollback() catch {};
        var consumed = try transaction.query(
            "DELETE FROM oauth_states WHERE state_hash = $1::bytea AND expires_at > now() RETURNING pkce_verifier, return_path",
            &.{&state_parameter},
        );
        defer consumed.deinit();
        if (consumed.rowCount() != 1) return error.OauthStateInvalid;
        const verifier = try self.allocator.dupe(u8, consumed.value(0, 0));
        defer {
            @memset(verifier, 0);
            self.allocator.free(verifier);
        }
        const return_path = try self.allocator.dupe(u8, sanitizeReturnPath(consumed.value(0, 1)));
        errdefer self.allocator.free(return_path);
        try transaction.commit();
        committed = true;

        const access_token = if (@import("builtin").is_test and self.test_urls != null)
            try exchangeAt(self.configuration, code, verifier, self.test_urls.?.token)
        else
            try self.endpoint.exchange(self.endpoint.context, code, verifier);
        defer if (self.endpoint.release_access_token) |release_access_token| release_access_token(self.endpoint.context, access_token);
        const identity = if (@import("builtin").is_test and self.test_urls != null)
            try fetchIdentityAt(access_token, self.test_urls.?.identity)
        else
            try self.endpoint.identity(self.endpoint.context, access_token);
        errdefer if (self.endpoint.release_identity) |release_identity| release_identity(self.endpoint.context, identity);
        try validateDiscordId(identity.id);
        return .{ .identity = identity, .return_path = return_path, .endpoint = self.endpoint };
    }

    pub fn upsertIdentity(self: *DiscordService, identity: DiscordIdentity) !i64 {
        var result = try self.pool.query(
            "INSERT INTO users (discord_id, discord_username, discord_global_name, discord_avatar_hash) VALUES ($1, $2, $3, $4) ON CONFLICT (discord_id) DO UPDATE SET discord_username = EXCLUDED.discord_username, discord_global_name = EXCLUDED.discord_global_name, discord_avatar_hash = EXCLUDED.discord_avatar_hash, updated_at = now() RETURNING id",
            &.{ identity.id, identity.username, identity.global_name, identity.avatar },
        );
        defer result.deinit();
        if (result.rowCount() != 1) return error.UserUpsertFailed;
        return std.fmt.parseInt(i64, result.value(0, 0), 10);
    }
};

pub fn sanitizeReturnPath(path: ?[]const u8) []const u8 {
    const value = path orelse return "/account";
    if (std.mem.eql(u8, value, "/") or std.mem.eql(u8, value, "/account")) return value;
    return "/account";
}

fn validateDiscordId(id: []const u8) !void {
    if (id.len == 0) return error.InvalidDiscordIdentity;
    for (id) |character| if (character < '0' or character > '9') return error.InvalidDiscordIdentity;
    _ = std.fmt.parseInt(u64, id, 10) catch return error.InvalidDiscordIdentity;
}

fn sha256(value: []const u8) [32]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &hash, .{});
    return hash;
}

fn encodeByteaParameter(source: []const u8, destination: []u8) void {
    destination[0] = '\\';
    destination[1] = 'x';
    encodeHex(source, destination[2..]);
}

fn encodeHex(source: []const u8, destination: []u8) void {
    const alphabet = "0123456789abcdef";
    for (source, 0..) |byte, index| {
        destination[index * 2] = alphabet[byte >> 4];
        destination[index * 2 + 1] = alphabet[byte & 0x0f];
    }
}

fn encodeBase64Url(source: []const u8, destination: []u8) void {
    _ = std.base64.url_safe_no_pad.Encoder.encode(destination, source);
}

fn exchangeProduction(context: *anyopaque, code: []const u8, verifier: []const u8) ![]const u8 {
    const configuration: *const config.Config = @ptrCast(@alignCast(context));
    return exchangeAt(configuration, code, verifier, "https://discord.com/api/oauth2/token");
}

fn exchangeAt(configuration: *const config.Config, code: []const u8, verifier: []const u8, url: []const u8) ![]const u8 {
    const encoded_client_id = try formEncode(std.heap.page_allocator, configuration.discord_client_id);
    defer std.heap.page_allocator.free(encoded_client_id);
    const encoded_client_secret = try formEncode(std.heap.page_allocator, configuration.discord_client_secret);
    defer {
        @memset(encoded_client_secret, 0);
        std.heap.page_allocator.free(encoded_client_secret);
    }
    const encoded_code = try formEncode(std.heap.page_allocator, code);
    defer {
        @memset(encoded_code, 0);
        std.heap.page_allocator.free(encoded_code);
    }
    const encoded_redirect_uri = try formEncode(std.heap.page_allocator, configuration.discord_redirect_uri);
    defer std.heap.page_allocator.free(encoded_redirect_uri);
    const encoded_verifier = try formEncode(std.heap.page_allocator, verifier);
    defer {
        @memset(encoded_verifier, 0);
        std.heap.page_allocator.free(encoded_verifier);
    }
    const payload = try std.fmt.allocPrint(std.heap.page_allocator, "client_id={s}&client_secret={s}&grant_type=authorization_code&code={s}&redirect_uri={s}&code_verifier={s}", .{ encoded_client_id, encoded_client_secret, encoded_code, encoded_redirect_uri, encoded_verifier });
    defer {
        @memset(payload, 0);
        std.heap.page_allocator.free(payload);
    }
    var body = std.ArrayList(u8).init(std.heap.page_allocator);
    defer {
        @memset(body.items, 0);
        body.deinit();
    }
    var client = std.http.Client{ .allocator = std.heap.page_allocator };
    defer client.deinit();
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .response_storage = .{ .dynamic = &body },
        .max_append_size = 64 * 1024,
        .extra_headers = &.{.{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" }},
    });
    if (result.status != .ok) return error.OauthProviderRejected;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body.items, .{});
    defer parsed.deinit();
    const token = parsed.value.object.get("access_token") orelse return error.InvalidProviderResponse;
    if (token != .string or token.string.len == 0) return error.InvalidProviderResponse;
    return try std.heap.page_allocator.dupe(u8, token.string);
}

fn fetchProductionIdentity(context: *anyopaque, access_token: []const u8) !DiscordIdentity {
    _ = context;
    return fetchIdentityAt(access_token, "https://discord.com/api/users/@me");
}

fn fetchIdentityAt(access_token: []const u8, url: []const u8) !DiscordIdentity {
    const authorization = try std.fmt.allocPrint(std.heap.page_allocator, "Bearer {s}", .{access_token});
    defer {
        @memset(authorization, 0);
        std.heap.page_allocator.free(authorization);
    }
    var body = std.ArrayList(u8).init(std.heap.page_allocator);
    defer body.deinit();
    var client = std.http.Client{ .allocator = std.heap.page_allocator };
    defer client.deinit();
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_storage = .{ .dynamic = &body },
        .max_append_size = 64 * 1024,
        .headers = .{ .authorization = .{ .override = authorization } },
        .redirect_behavior = .unhandled,
    });
    if (result.status != .ok) return error.OauthProviderRejected;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body.items, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    const id = object.get("id") orelse return error.InvalidProviderResponse;
    const username = object.get("username") orelse return error.InvalidProviderResponse;
    if (id != .string or username != .string) return error.InvalidProviderResponse;
    const global_name = object.get("global_name");
    const avatar = object.get("avatar");
    const id_copy = try std.heap.page_allocator.dupe(u8, id.string);
    errdefer std.heap.page_allocator.free(id_copy);
    const username_copy = try std.heap.page_allocator.dupe(u8, username.string);
    errdefer std.heap.page_allocator.free(username_copy);
    const global_name_copy = if (global_name != null and global_name.? == .string) try std.heap.page_allocator.dupe(u8, global_name.?.string) else null;
    errdefer if (global_name_copy) |value| std.heap.page_allocator.free(value);
    const avatar_copy = if (avatar != null and avatar.? == .string) try std.heap.page_allocator.dupe(u8, avatar.?.string) else null;
    return .{ .id = id_copy, .username = username_copy, .global_name = global_name_copy, .avatar = avatar_copy };
}

fn releaseAllocatedToken(_: *anyopaque, access_token: []const u8) void {
    @memset(@constCast(access_token), 0);
    std.heap.page_allocator.free(access_token);
}

fn releaseAllocatedIdentity(_: *anyopaque, identity: DiscordIdentity) void {
    std.heap.page_allocator.free(identity.id);
    std.heap.page_allocator.free(identity.username);
    if (identity.global_name) |value| std.heap.page_allocator.free(value);
    if (identity.avatar) |value| std.heap.page_allocator.free(value);
}

fn formEncode(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer {
        @memset(output.items, 0);
        output.deinit();
    }
    const hex = "0123456789ABCDEF";
    for (value) |character| {
        const unreserved = std.ascii.isAlphanumeric(character) or character == '-' or character == '_' or character == '.' or character == '~';
        if (unreserved) {
            try output.append(character);
        } else {
            try output.append('%');
            try output.append(hex[character >> 4]);
            try output.append(hex[character & 0x0f]);
        }
    }
    return output.toOwnedSlice();
}
