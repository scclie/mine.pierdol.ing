const std = @import("std");
const db = @import("db_pool");
const config = @import("config");
const http = @import("http_server");
const build = @import("mojang_build");
const c = @cImport({
    @cInclude("curl/curl.h");
});

pub const Provider = struct {
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    configuration: *const config.Config,
    refreshed: ?std.time.Instant = null,
    online: ?u32 = null,
    uptime: ?f64 = null,
    approved: ?u64 = null,
    discord_refreshed: ?std.time.Instant = null,
    discord: DiscordCounts = .{},

    pub fn init(allocator: std.mem.Allocator, pool: *db.Pool, configuration: *const config.Config) Provider {
        return .{ .allocator = allocator, .pool = pool, .configuration = configuration };
    }

    // The HTTP server serializes handlers (including this shared libpq connection).
    fn refresh(self: *Provider) void {
        const now = std.time.Instant.now() catch null;
        if (now) |instant| {
            if (self.refreshed) |previous| {
                if (instant.since(previous) < 15 * std.time.ns_per_s) return;
            }
        }
        self.online = ping(self.allocator, self.configuration) catch null;
        self.uptime = fetchUptime(self.allocator, self.configuration.one_island_gatus_uptime_url) catch null;
        self.approved = self.countApproved() catch null;
        self.refreshed = std.time.Instant.now() catch null;
    }

    fn countApproved(self: *Provider) !u64 {
        // Kept local to this provider: no changes to account/admin repositories.
        var result = try self.pool.query("SELECT COUNT(*) FROM applications WHERE status = 'approved'", &.{});
        defer result.deinit();
        if (result.rowCount() != 1) return error.InvalidCount;
        const value = result.value(0, 0);
        if (value.len == 0) return error.InvalidCount;
        for (value) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidCount;
        return std.fmt.parseInt(u64, value, 10);
    }

    fn refreshDiscord(self: *Provider) void {
        const now = std.time.Instant.now() catch return;
        if (self.discord_refreshed) |previous| {
            if (now.since(previous) < 3600 * std.time.ns_per_s) return;
        }
        // Cache failures too, independently of the other statistics sources.
        self.discord_refreshed = now;
        self.discord = fetchDiscord(self.allocator, self.configuration.one_island_discord_invite_url) catch .{};
    }
};

pub fn register(server: *http.Server, provider: *Provider) !void {
    try server.route(.GET, "/api/v1/public/servers", provider, handle);
}

fn handle(context: *anyopaque, _: http.Request, _: []const u8) !http.response.Response {
    const provider: *Provider = @ptrCast(@alignCast(context));
    provider.refresh();
    provider.refreshDiscord();
    const elapsed = @as(i128, std.time.timestamp()) - @as(i128, provider.configuration.one_island_wipe_unix_seconds);
    const payload = .{ .servers = .{
        .{
            .id = "one-island",
            .status = @as([]const u8, if (provider.online != null) "online" else "offline"),
            .online = provider.online,
            .stats = .{
                .uptime_7d_percent = provider.uptime,
                .approved_applications = provider.approved,
                .wipe_elapsed_seconds = elapsed,
                .uptime_url = "https://status.sccl.cc/endpoints/games_mine-skyblock-server",
                .discord = provider.discord,
            },
        },
        .{ .id = "draumur1", .status = "planned", .online = @as(?u32, null) },
    } };
    const body = try std.json.stringifyAlloc(provider.allocator, payload, .{});
    defer provider.allocator.free(body);
    var result = try http.response.Response.init(provider.allocator, 200, body);
    errdefer result.deinit();
    try result.addHeader("Content-Type", "application/json; charset=utf-8");
    try result.addHeader("Cache-Control", "public, max-age=15");
    return result;
}

// One absolute two-second budget covers connect, writes, and the full response.
const StatusSocket = struct {
    fd: std.posix.socket_t,
    timer: std.time.Timer,

    fn wait(self: *StatusSocket, events: i16) !void {
        const elapsed = self.timer.read() / std.time.ns_per_ms;
        if (elapsed >= 2000) return error.Timeout;
        var descriptors = [_]std.posix.pollfd{.{ .fd = self.fd, .events = events, .revents = 0 }};
        if (try std.posix.poll(&descriptors, @intCast(2000 - elapsed)) == 0) return error.Timeout;
        if (descriptors[0].revents & std.posix.POLL.NVAL != 0) return error.InvalidSocket;
    }

    fn write(self: *StatusSocket, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            try self.wait(std.posix.POLL.OUT);
            const count = std.posix.send(self.fd, bytes[offset..], std.posix.MSG.NOSIGNAL) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            if (count == 0) return error.Closed;
            offset += count;
        }
    }

    fn read(self: *StatusSocket, bytes: []u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            try self.wait(std.posix.POLL.IN);
            const count = std.posix.recv(self.fd, bytes[offset..], 0) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            if (count == 0) return error.Closed;
            offset += count;
        }
    }

    fn varInt(self: *StatusSocket) !u32 {
        var value: u32 = 0;
        for (0..5) |index| {
            var byte: [1]u8 = undefined;
            try self.read(&byte);
            if (index == 4 and byte[0] & 0xf8 != 0) return error.InvalidVarInt;
            value |= @as(u32, byte[0] & 0x7f) << @as(u5, @intCast(index * 7));
            if (byte[0] & 0x80 == 0) return value;
        }
        return error.InvalidVarInt;
    }
};

fn appendVarInt(bytes: *std.ArrayList(u8), number: u32) !void {
    var value = number;
    while (value >= 0x80) {
        try bytes.append(@as(u8, @intCast(value & 0x7f)) | 0x80);
        value >>= 7;
    }
    try bytes.append(@intCast(value));
}

fn ping(allocator: std.mem.Allocator, configuration: *const config.Config) !u32 {
    const address = try std.net.Address.parseIp(configuration.one_island_status_address, configuration.one_island_status_port);
    const fd = try std.posix.socket(address.any.family, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC, std.posix.IPPROTO.TCP);
    defer std.posix.close(fd);
    var socket = StatusSocket{ .fd = fd, .timer = try std.time.Timer.start() };
    std.posix.connect(fd, &address.any, address.getOsSockLen()) catch |err| switch (err) {
        error.WouldBlock, error.ConnectionPending => {
            try socket.wait(std.posix.POLL.OUT);
            try std.posix.getsockoptError(fd);
        },
        else => return err,
    };
    var handshake = std.ArrayList(u8).init(allocator);
    defer handshake.deinit();
    try appendVarInt(&handshake, 0); // handshake packet id
    try appendVarInt(&handshake, 767); // status works independently of login version
    try appendVarInt(&handshake, @intCast(configuration.one_island_status_address.len));
    try handshake.appendSlice(configuration.one_island_status_address);
    try handshake.append(@intCast(configuration.one_island_status_port >> 8));
    try handshake.append(@intCast(configuration.one_island_status_port & 0xff));
    try appendVarInt(&handshake, 1); // next state: status
    var packet = std.ArrayList(u8).init(allocator);
    defer packet.deinit();
    try appendVarInt(&packet, @intCast(handshake.items.len));
    try packet.appendSlice(handshake.items);
    try packet.appendSlice(&.{ 1, 0 }); // status request
    try socket.write(packet.items);
    const packet_length = try socket.varInt();
    if (packet_length < 3 or packet_length > 65536) return error.InvalidStatus;
    const bytes = try allocator.alloc(u8, packet_length);
    defer allocator.free(bytes);
    try socket.read(bytes);
    var input = std.io.fixedBufferStream(bytes);
    if (try input.reader().readByte() != 0) return error.InvalidStatus;
    var json_length: u32 = 0;
    var complete = false;
    for (0..5) |index| {
        const byte = try input.reader().readByte();
        if (index == 4 and byte & 0xf8 != 0) return error.InvalidStatus;
        json_length |= @as(u32, byte & 0x7f) << @as(u5, @intCast(index * 7));
        if (byte & 0x80 == 0) {
            complete = true;
            break;
        }
    }
    if (!complete or json_length != bytes.len - input.pos) return error.InvalidStatus;
    const Status = struct { players: struct { online: u32 } };
    const parsed = try std.json.parseFromSlice(Status, allocator, bytes[input.pos..], .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return parsed.value.players.online;
}

const UptimeBody = struct {
    bytes: [128]u8 = undefined,
    len: usize = 0,

    fn write(ptr: [*c]u8, size: usize, count: usize, context: ?*anyopaque) callconv(.C) usize {
        const self: *UptimeBody = @ptrCast(@alignCast(context orelse return 0));
        const length = std.math.mul(usize, size, count) catch return 0;
        if (length > self.bytes.len - self.len or (length != 0 and ptr == null)) return 0;
        if (length != 0) @memcpy(self.bytes[self.len..][0..length], ptr[0..length]);
        self.len += length;
        return length;
    }
};

fn curlCheck(code: c.CURLcode) !void {
    if (code != c.CURLE_OK) return error.UptimeUnavailable;
}

const DiscordCounts = struct {
    online: ?u64 = null,
    members: ?u64 = null,
};

const DiscordBody = struct {
    bytes: [65536]u8 = undefined,
    len: usize = 0,

    fn write(ptr: [*c]u8, size: usize, count: usize, context: ?*anyopaque) callconv(.C) usize {
        const self: *DiscordBody = @ptrCast(@alignCast(context orelse return 0));
        const length = std.math.mul(usize, size, count) catch return 0;
        if (length > self.bytes.len - self.len or (length != 0 and ptr == null)) return 0;
        if (length != 0) @memcpy(self.bytes[self.len..][0..length], ptr[0..length]);
        self.len += length;
        return length;
    }
};

fn discordCount(value: std.json.Value) !u64 {
    if (value != .integer) return error.InvalidDiscordCount;
    if (value.integer < 0 or value.integer > 9007199254740991) return error.InvalidDiscordCount;
    return @intCast(value.integer);
}

fn fetchDiscord(allocator: std.mem.Allocator, url: []const u8) !DiscordCounts {
    const easy = c.curl_easy_init() orelse return error.DiscordUnavailable;
    defer c.curl_easy_cleanup(easy);
    const endpoint = try allocator.dupeZ(u8, url);
    defer allocator.free(endpoint);
    try curlCheck(c.curl_easy_setopt(easy, c.CURLOPT_URL, endpoint.ptr));
    inline for (.{
        .{ c.CURLOPT_PROTOCOLS_STR, "https" },
        .{ c.CURLOPT_PROXY, "" },
        .{ c.CURLOPT_NOPROXY, "*" },
        .{ c.CURLOPT_CAINFO, build.ca_bundle ++ "\x00" },
        .{ c.CURLOPT_CAPATH, "" },
    }) |option| try curlCheck(c.curl_easy_setopt(easy, option[0], @as([*:0]const u8, option[1])));
    inline for (.{
        .{ c.CURLOPT_TIMEOUT_MS, 2000 },
        .{ c.CURLOPT_CONNECTTIMEOUT_MS, 1500 },
        .{ c.CURLOPT_NOSIGNAL, 1 },
        .{ c.CURLOPT_FOLLOWLOCATION, 0 },
        .{ c.CURLOPT_SSL_VERIFYPEER, 1 },
        .{ c.CURLOPT_SSL_VERIFYHOST, 2 },
        .{ c.CURLOPT_NETRC, c.CURL_NETRC_IGNORED },
    }) |option| try curlCheck(c.curl_easy_setopt(easy, option[0], @as(c_long, option[1])));
    var body = DiscordBody{};
    try curlCheck(c.curl_easy_setopt(easy, c.CURLOPT_WRITEFUNCTION, @as(*const fn ([*c]u8, usize, usize, ?*anyopaque) callconv(.C) usize, DiscordBody.write)));
    try curlCheck(c.curl_easy_setopt(easy, c.CURLOPT_WRITEDATA, @as(*anyopaque, @ptrCast(&body))));
    try curlCheck(c.curl_easy_perform(easy));
    var status: c_long = 0;
    try curlCheck(c.curl_easy_getinfo(easy, c.CURLINFO_RESPONSE_CODE, &status));
    if (status != 200) return error.DiscordUnavailable;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body.bytes[0..body.len], .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidDiscordCounts;
    return .{
        .online = try discordCount(parsed.value.object.get("approximate_presence_count") orelse return error.InvalidDiscordCounts),
        .members = try discordCount(parsed.value.object.get("approximate_member_count") orelse return error.InvalidDiscordCounts),
    };
}

fn fetchUptime(allocator: std.mem.Allocator, url: []const u8) !f64 {
    // main initializes libcurl through its existing transport Client first.
    const easy = c.curl_easy_init() orelse return error.UptimeUnavailable;
    defer c.curl_easy_cleanup(easy);
    const endpoint = try allocator.dupeZ(u8, url);
    defer allocator.free(endpoint);
    try curlCheck(c.curl_easy_setopt(easy, c.CURLOPT_URL, endpoint.ptr));
    inline for (.{
        .{ c.CURLOPT_PROTOCOLS_STR, "https" },
        .{ c.CURLOPT_PROXY, "" },
        .{ c.CURLOPT_NOPROXY, "*" },
        .{ c.CURLOPT_CAINFO, build.ca_bundle ++ "\x00" },
        .{ c.CURLOPT_CAPATH, "" },
    }) |option| try curlCheck(c.curl_easy_setopt(easy, option[0], @as([*:0]const u8, option[1])));
    inline for (.{
        .{ c.CURLOPT_TIMEOUT_MS, 2000 },
        .{ c.CURLOPT_CONNECTTIMEOUT_MS, 1500 },
        .{ c.CURLOPT_NOSIGNAL, 1 },
        .{ c.CURLOPT_FOLLOWLOCATION, 0 },
        .{ c.CURLOPT_SSL_VERIFYPEER, 1 },
        .{ c.CURLOPT_SSL_VERIFYHOST, 2 },
        .{ c.CURLOPT_NETRC, c.CURL_NETRC_IGNORED },
    }) |option| try curlCheck(c.curl_easy_setopt(easy, option[0], @as(c_long, option[1])));
    var body = UptimeBody{};
    try curlCheck(c.curl_easy_setopt(easy, c.CURLOPT_WRITEFUNCTION, @as(*const fn ([*c]u8, usize, usize, ?*anyopaque) callconv(.C) usize, UptimeBody.write)));
    try curlCheck(c.curl_easy_setopt(easy, c.CURLOPT_WRITEDATA, @as(*anyopaque, @ptrCast(&body))));
    try curlCheck(c.curl_easy_perform(easy));
    var status: c_long = 0;
    try curlCheck(c.curl_easy_getinfo(easy, c.CURLINFO_RESPONSE_CODE, &status));
    if (status != 200) return error.UptimeUnavailable;
    const raw = std.mem.trim(u8, body.bytes[0..body.len], " \t\r\n");
    if (raw.len == 0) return error.InvalidUptime;
    var dots: usize = 0;
    var digits: usize = 0;
    for (raw) |byte| {
        if (byte == '.') {
            dots += 1;
        } else if (std.ascii.isDigit(byte)) {
            digits += 1;
        } else return error.InvalidUptime;
    }
    if (dots > 1 or digits == 0) return error.InvalidUptime;
    const fraction = try std.fmt.parseFloat(f64, raw);
    if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1) return error.InvalidUptime;
    return fraction * 100;
}
