const std = @import("std");

pub const Config = struct {
    allocator: std.mem.Allocator,
    database_url: []u8,
    http_listen_address: []u8,
    public_origin: []u8,
    discord_client_id: []u8,
    discord_client_secret: []u8,
    discord_redirect_uri: []u8,
    session_signing_key: []u8,
    administrator_discord_ids: std.AutoHashMap(u64, void),
    moderator_discord_ids: std.AutoHashMap(u64, void),
    development_mode: bool,

    pub fn load(allocator: std.mem.Allocator) !Config {
        const database_url = try duplicateRequired(allocator, "DATABASE_URL", error.InvalidDatabaseUrl);
        errdefer wipeFree(allocator, database_url);
        const http_listen_address = try duplicateRequired(allocator, "HTTP_LISTEN_ADDRESS", error.InvalidHttpListenAddress);
        errdefer allocator.free(http_listen_address);
        const public_origin = try duplicateRequired(allocator, "PUBLIC_ORIGIN", error.InvalidPublicOrigin);
        errdefer allocator.free(public_origin);
        const discord_client_id = try duplicateRequired(allocator, "DISCORD_CLIENT_ID", error.InvalidDiscordClientId);
        errdefer allocator.free(discord_client_id);
        const discord_client_secret = try duplicateRequired(allocator, "DISCORD_CLIENT_SECRET", error.InvalidDiscordClientSecret);
        errdefer wipeFree(allocator, discord_client_secret);
        const discord_redirect_uri = try duplicateRequired(allocator, "DISCORD_REDIRECT_URI", error.InvalidDiscordRedirectUri);
        errdefer allocator.free(discord_redirect_uri);
        const session_signing_key = try duplicateRequired(allocator, "SESSION_SIGNING_KEY", error.InvalidSessionSigningKey);
        errdefer wipeFree(allocator, session_signing_key);
        if (session_signing_key.len < 32) return error.InvalidSessionSigningKey;

        const public_url = parsePublicOrigin(public_origin) catch return error.InvalidPublicOrigin;
        const development_mode = environmentIs("DEVELOPMENT_MODE", "true");
        if (!development_mode and !std.mem.eql(u8, public_url.scheme, "https")) return error.InvalidPublicOrigin;
        const callback_url = parseCallbackUrl(discord_redirect_uri) catch return error.InvalidDiscordRedirectUri;
        if (!urlsShareOrigin(public_url, callback_url)) return error.InvalidDiscordRedirectUri;

        var administrator_discord_ids = std.AutoHashMap(u64, void).init(allocator);
        errdefer administrator_discord_ids.deinit();
        var moderator_discord_ids = std.AutoHashMap(u64, void).init(allocator);
        errdefer moderator_discord_ids.deinit();
        try parseDiscordIds(&administrator_discord_ids, environmentValue("ADMIN_DISCORD_IDS") orelse "");
        try parseDiscordIds(&moderator_discord_ids, environmentValue("MODERATOR_DISCORD_IDS") orelse "");
        var iterator = administrator_discord_ids.keyIterator();
        while (iterator.next()) |discord_id| {
            if (moderator_discord_ids.contains(discord_id.*)) return error.OverlappingRoleDiscordId;
        }

        return .{
            .allocator = allocator,
            .database_url = database_url,
            .http_listen_address = http_listen_address,
            .public_origin = public_origin,
            .discord_client_id = discord_client_id,
            .discord_client_secret = discord_client_secret,
            .discord_redirect_uri = discord_redirect_uri,
            .session_signing_key = session_signing_key,
            .administrator_discord_ids = administrator_discord_ids,
            .moderator_discord_ids = moderator_discord_ids,
            .development_mode = development_mode,
        };
    }

    pub fn deinit(self: *Config) void {
        wipeFree(self.allocator, self.database_url);
        self.allocator.free(self.http_listen_address);
        self.allocator.free(self.public_origin);
        self.allocator.free(self.discord_client_id);
        wipeFree(self.allocator, self.discord_client_secret);
        self.allocator.free(self.discord_redirect_uri);
        wipeFree(self.allocator, self.session_signing_key);
        self.administrator_discord_ids.deinit();
        self.moderator_discord_ids.deinit();
    }
};

fn environmentValue(name: [:0]const u8) ?[]const u8 {
    return std.posix.getenv(name);
}

fn environmentIs(name: [:0]const u8, expected: []const u8) bool {
    const value = environmentValue(name) orelse return false;
    return std.mem.eql(u8, value, expected);
}

fn duplicateRequired(allocator: std.mem.Allocator, name: [:0]const u8, comptime invalid_error: anyerror) ![]u8 {
    const value = environmentValue(name) orelse return invalid_error;
    if (value.len == 0) return invalid_error;
    return allocator.dupe(u8, value);
}

fn wipeFree(allocator: std.mem.Allocator, value: []u8) void {
    @memset(value, 0);
    allocator.free(value);
}

fn parseDiscordIds(destination: *std.AutoHashMap(u64, void), raw: []const u8) !void {
    if (raw.len == 0) return;

    var values = std.mem.splitScalar(u8, raw, ',');
    while (values.next()) |untrimmed_value| {
        const value = std.mem.trim(u8, untrimmed_value, " \t\r\n");
        if (value.len == 0) return error.InvalidDiscordId;
        for (value) |character| {
            if (character < '0' or character > '9') return error.InvalidDiscordId;
        }
        const discord_id = std.fmt.parseInt(u64, value, 10) catch return error.InvalidDiscordId;
        const entry = try destination.getOrPut(discord_id);
        if (entry.found_existing) return error.DuplicateDiscordId;
        entry.value_ptr.* = {};
    }
}

const ParsedUrl = struct {
    scheme: []const u8,
    host: []const u8,
    effective_port: u16,
};

fn parsePublicOrigin(value: []const u8) !ParsedUrl {
    const strict_uri = try parseHttpUrl(value);
    if (!strict_uri.uri.path.isEmpty() or strict_uri.uri.query != null or strict_uri.uri.fragment != null) return error.InvalidPublicOrigin;
    return parsedUrl(strict_uri);
}

fn parseCallbackUrl(value: []const u8) !ParsedUrl {
    const strict_uri = try parseHttpUrl(value);
    if (strict_uri.uri.path.isEmpty()) return error.InvalidDiscordRedirectUri;
    return parsedUrl(strict_uri);
}

const StrictUri = struct {
    uri: std.Uri,
    authority: RawAuthority,
};

const RawAuthority = struct {
    host: []const u8,
    port: ?u16,
};

fn parseHttpUrl(value: []const u8) !StrictUri {
    const uri = try std.Uri.parse(value);
    if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) return error.InvalidUrlScheme;
    if (uri.user != null or uri.password != null) return error.InvalidUrlAuthority;

    const authority = try parseRawAuthority(value, uri.scheme);
    const parsed_host = componentBytes(uri.host orelse return error.InvalidUrlAuthority);
    if (!std.mem.eql(u8, parsed_host, authority.host) or !optionalPortEql(uri.port, authority.port)) return error.InvalidUrlAuthority;
    try validateHost(authority.host);
    return .{ .uri = uri, .authority = authority };
}

fn parseRawAuthority(value: []const u8, scheme: []const u8) !RawAuthority {
    const authority_start: usize = if (std.mem.eql(u8, scheme, "http") and std.mem.startsWith(u8, value, "http://")) 7 else if (std.mem.eql(u8, scheme, "https") and std.mem.startsWith(u8, value, "https://")) 8 else return error.InvalidUrlAuthority;
    const authority = value[authority_start .. authority_start + authorityLength(value[authority_start..])];
    if (authority.len == 0 or std.mem.indexOfScalar(u8, authority, '@') != null) return error.InvalidUrlAuthority;

    if (authority[0] == '[') {
        const closing_bracket = std.mem.indexOfScalar(u8, authority, ']') orelse return error.InvalidUrlAuthority;
        const host = authority[0 .. closing_bracket + 1];
        const suffix = authority[closing_bracket + 1 ..];
        return .{ .host = host, .port = try parsePortSuffix(suffix) };
    }

    const first_colon = std.mem.indexOfScalar(u8, authority, ':');
    if (first_colon) |colon| {
        if (std.mem.indexOfScalarPos(u8, authority, colon + 1, ':') != null) return error.InvalidUrlAuthority;
        return .{
            .host = authority[0..colon],
            .port = try parsePortSuffix(authority[colon..]),
        };
    }
    return .{ .host = authority, .port = null };
}

fn authorityLength(value: []const u8) usize {
    for (value, 0..) |character, index| {
        if (character == '/' or character == '?' or character == '#') return index;
    }
    return value.len;
}

fn parsePortSuffix(suffix: []const u8) !?u16 {
    if (suffix.len == 0) return null;
    if (suffix[0] != ':' or suffix.len == 1) return error.InvalidUrlAuthority;
    const raw_port = suffix[1..];
    for (raw_port) |character| {
        if (character < '0' or character > '9') return error.InvalidUrlAuthority;
    }
    return std.fmt.parseInt(u16, raw_port, 10) catch error.InvalidUrlAuthority;
}

fn optionalPortEql(left: ?u16, right: ?u16) bool {
    if (left) |left_port| return if (right) |right_port| left_port == right_port else false;
    return right == null;
}

fn parsedUrl(strict_uri: StrictUri) !ParsedUrl {
    const host = strict_uri.uri.host orelse return error.InvalidUrlAuthority;
    return .{
        .scheme = strict_uri.uri.scheme,
        .host = componentBytes(host),
        .effective_port = strict_uri.authority.port orelse if (std.mem.eql(u8, strict_uri.uri.scheme, "https")) 443 else 80,
    };
}

fn componentBytes(component: std.Uri.Component) []const u8 {
    return switch (component) {
        .raw, .percent_encoded => |value| value,
    };
}

fn urlsShareOrigin(left: ParsedUrl, right: ParsedUrl) bool {
    return std.mem.eql(u8, left.scheme, right.scheme) and left.effective_port == right.effective_port and hostsEqual(left.host, right.host);
}

fn hostsEqual(left: []const u8, right: []const u8) bool {
    if (isBracketedIpv6(left) and isBracketedIpv6(right)) {
        const left_address = std.net.Address.parseIp6(left[1 .. left.len - 1], 0) catch return false;
        const right_address = std.net.Address.parseIp6(right[1 .. right.len - 1], 0) catch return false;
        return std.net.Address.eql(left_address, right_address);
    }
    if (looksLikeIpv4(left) and looksLikeIpv4(right)) {
        const left_address = std.net.Address.parseIp4(left, 0) catch return false;
        const right_address = std.net.Address.parseIp4(right, 0) catch return false;
        return std.net.Address.eql(left_address, right_address);
    }
    return std.ascii.eqlIgnoreCase(left, right);
}

fn validateHost(host: []const u8) !void {
    if (isBracketedIpv6(host)) {
        _ = std.net.Address.parseIp6(host[1 .. host.len - 1], 0) catch return error.InvalidUrlHost;
        return;
    }
    if (std.mem.indexOfScalar(u8, host, '[') != null or std.mem.indexOfScalar(u8, host, ']') != null) return error.InvalidUrlHost;
    if (looksLikeIpv4(host)) {
        _ = std.net.Address.parseIp4(host, 0) catch return error.InvalidUrlHost;
        return;
    }
    try validateHostname(host);
}

fn isBracketedIpv6(host: []const u8) bool {
    return host.len >= 3 and host[0] == '[' and host[host.len - 1] == ']';
}

fn looksLikeIpv4(host: []const u8) bool {
    if (std.mem.indexOfScalar(u8, host, '.') == null) return false;
    for (host) |character| {
        if ((character < '0' or character > '9') and character != '.') return false;
    }
    return true;
}

fn validateHostname(host: []const u8) !void {
    if (host.len == 0 or host.len > 253) return error.InvalidUrlHost;
    var labels = std.mem.splitScalar(u8, host, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63 or label[0] == '-' or label[label.len - 1] == '-') return error.InvalidUrlHost;
        for (label) |character| {
            const is_alpha = (character >= 'a' and character <= 'z') or (character >= 'A' and character <= 'Z');
            const is_digit = character >= '0' and character <= '9';
            if (!is_alpha and !is_digit and character != '-') return error.InvalidUrlHost;
        }
    }
}
