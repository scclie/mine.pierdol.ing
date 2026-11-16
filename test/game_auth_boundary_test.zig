const std = @import("std");
const routes = @import("game_auth_routes");
const service = @import("game_auth_service");
const config = @import("config");
const http = @import("http_server");
const a = std.testing.allocator;
fn configuration() config.Config {
    var c: config.Config = undefined;
    c.game_auth_credentials = @constCast(&[_]config.GameAuthCredential{.{ .server_id = @constCast("test"), .secret = @constCast("SYNTHETIC_SECRET") }});
    return c;
}
fn initRouter(c: *const config.Config) routes.Router {
    return .{ .allocator = a, .configuration = c, .service = .{ .allocator = a, .repository = .{ .allocator = a }, .limiter = service.AttemptLimiter.init(a), .clock = frozenClock } };
}
fn frozenClock() i64 {
    return 0;
}
fn check(result: *http.response.Response, status: u16) !void {
    try std.testing.expectEqual(status, result.status);
    try std.testing.expectEqualStrings("application/json", result.header("Content-Type") orelse "");
    try std.testing.expectEqualStrings("no-store", result.header("Cache-Control") orelse "");
    for ([_][]const u8{ "SYNTHETIC_SECRET", "PASSWORD_SENTINEL", "StorageUnavailable", "AuditUnavailable" }) |secret|
        try std.testing.expect(std.mem.indexOf(u8, result.body, secret) == null);
}
test "game-auth boundary rejects equal config secrets and duplicate IDs" {
    if (comptime @hasDecl(config, "parseGameAuthCredentials")) {
        try std.testing.expectError(error.DuplicateGameAuthSecret, config.parseGameAuthCredentials(a, try a.dupe(u8, "one:same,two:same")));
        try std.testing.expectError(error.DuplicateGameAuthServerId, config.parseGameAuthCredentials(a, try a.dupe(u8, "one:first,one:second")));
    } else try std.testing.expect(false);
}
test "game-auth boundary authenticates before content type and unknown route errors" {
    const c = configuration();
    var router = initRouter(&c);
    defer router.deinit();
    var server = http.Server.init(a);
    defer server.deinit();
    try routes.register(&server, &router);
    for ([_][]const u8{ "/internal/game-auth/v1/cracked-login", "/internal/game-auth/v1/unknown" }) |target| {
        var result = try server.dispatch(.{ .method = .POST, .target = target, .content_type = "text/plain" });
        defer result.deinit();
        try check(&result, 401);
    }
}
test "game-auth boundary policy route strictly parses query and hides metadata" {
    const c = configuration();
    var router = initRouter(&c);
    defer router.deinit();
    var server = http.Server.init(a);
    defer server.deinit();
    try routes.register(&server, &router);
    const cases = [_]struct { target: []const u8, status: u16 }{
        .{ .target = "identity-policy?nickname=Player", .status = 200 },
        .{ .target = "identity-policy?nickname=%50layer", .status = 200 },
        .{ .target = "identity-policy?nickname=Player&nickname=Other", .status = 400 },
        .{ .target = "identity-policy?nickname=%GG", .status = 400 },
        .{ .target = "identity-policy?nickname=%00", .status = 400 },
        .{ .target = "identity-policy?other=Player", .status = 400 },
        .{ .target = "identity-policy", .status = 400 },
        .{ .target = "whitelist?cursor=+1", .status = 400 },
        .{ .target = "whitelist?cursor=18446744073709551616", .status = 400 },
        .{ .target = "whitelist?cursor=1&cursor=1", .status = 400 },
    };
    for (cases) |case| {
        const target = try std.mem.concat(a, u8, &.{ "/internal/game-auth/v1/", case.target });
        defer a.free(target);
        var result = try server.dispatch(.{ .method = .GET, .target = target, .authorization = "Bearer SYNTHETIC_SECRET" });
        defer result.deinit();
        try check(&result, case.status);
        if (case.status == 200) try std.testing.expectEqualStrings("{\"outcome\":\"denied\"}", result.body);
    }
}
test "game-auth boundary cursor signed bigint limit rejects overflow before snapshot access" {
    const c = configuration();
    const cases = [_]struct { decimal: []const u8, status: u16, calls: usize }{
        .{ .decimal = "9223372036854775807", .status = 200, .calls = 1 },
        .{ .decimal = "9223372036854775808", .status = 400, .calls = 0 },
        .{ .decimal = "18446744073709551615", .status = 400, .calls = 0 },
    };
    var statuses: [cases.len]u16 = undefined;
    var calls: [cases.len]usize = undefined;
    for (cases, 0..) |case, index| {
        var router = initRouter(&c);
        defer router.deinit();
        var server = http.Server.init(a);
        defer server.deinit();
        try routes.register(&server, &router);
        const target = try std.mem.concat(a, u8, &.{ "/internal/game-auth/v1/whitelist?cursor=", case.decimal });
        defer a.free(target);
        var result = try server.dispatch(.{ .method = .GET, .target = target, .authorization = "Bearer SYNTHETIC_SECRET" });
        defer result.deinit();
        statuses[index] = result.status;
        calls[index] = router.service.repository.snapshot_calls;
        std.debug.print("CURSOR boundary decimal={s} HTTP={d} snapshot_calls={d}\n", .{ case.decimal, result.status, calls[index] });
        if (result.status == 400) {
            try std.testing.expectEqualStrings("{\"outcome\":\"deny\"}", result.body);
        } else if (index == 0) try std.testing.expectEqual(@as(?u64, 9223372036854775807), router.service.repository.last_cursor);
    }
    for (cases, 0..) |case, index| {
        try std.testing.expectEqual(case.status, statuses[index]);
        try std.testing.expectEqual(case.calls, calls[index]);
    }
}

test "game-auth boundary malformed exact POST schemas return generic 400 not 500" {
    const c = configuration();
    const bodies = [_][]const u8{ "{", "{}", "[]", "{\"nickname\":\"Player\",\"password\":\"x\",\"extra\":1}", "{\"nickname\":\"Player\",\"password\":\"x\",\"password\":\"y\"}", "{\"nickname\":\"Player\",\"password\":null}", "{\"nickname\":\"Player\",\"password\":\"\"}", "{\"nickname\":\"Player\",\"password\":\"\\u0000\"}" };
    for (bodies) |body| {
        var router = initRouter(&c);
        defer router.deinit();
        var server = http.Server.init(a);
        defer server.deinit();
        try routes.register(&server, &router);
        var result = try server.dispatch(.{ .method = .POST, .target = "/internal/game-auth/v1/cracked-login", .authorization = "Bearer SYNTHETIC_SECRET", .content_type = "application/json", .content_length = body.len, .body = body });
        defer result.deinit();
        try check(&result, 400);
    }
}
test "game-auth boundary limiter retains protected key at 4096 active keys and expires exactly" {
    if (comptime @hasDecl(service, "AttemptLimiter")) {
        var limiter = service.AttemptLimiter.init(a);
        defer limiter.deinit();
        for (0..5) |_| try std.testing.expect(try limiter.nickname("server", "protected", 0));
        try std.testing.expect(!try limiter.nickname("server", "protected", 0));
        for (0..4095) |i| {
            var buffer: [32]u8 = undefined;
            try std.testing.expect(try limiter.nickname("server", try std.fmt.bufPrint(&buffer, "name{d}", .{i}), 0));
        }
        try std.testing.expect(!try limiter.nickname("server", "overflow", 59999));
        try std.testing.expect(!try limiter.nickname("server", "protected", 59999));
        try std.testing.expect(try limiter.nickname("server", "overflow", 60000));
        try std.testing.expect(try limiter.nickname("server", "protected", 60000));
    } else try std.testing.expect(false);
}
test "game-auth boundary successful premium attempts and session requests exhaust budgets" {
    const c = configuration();
    var router = initRouter(&c);
    defer router.deinit();
    router.service.repository.allow = true;
    var server = http.Server.init(a);
    defer server.deinit();
    try routes.register(&server, &router);
    for (0..6) |i| {
        var result = try server.dispatch(.{ .method = .POST, .target = "/internal/game-auth/v1/premium-verified", .authorization = "Bearer SYNTHETIC_SECRET", .content_type = "application/json", .content_length = 41, .body = if (i % 2 == 0) "{\"nickname\":\"Player\",\"mojang_uuid\":\"uuid\"}" else "{\"nickname\":\"player\",\"mojang_uuid\":\"uuid\"}" });
        defer result.deinit();
        try check(&result, if (i < 5) 200 else 429);
    }
    for (0..120) |i| {
        var result = try server.dispatch(.{ .method = .POST, .target = "/internal/game-auth/v1/session-check", .authorization = "Bearer SYNTHETIC_SECRET", .content_type = "application/json", .content_length = 19, .body = "{\"lease\":\"invalid\"}" });
        defer result.deinit();
        try check(&result, if (i < 114) 200 else 429);
    }
}

const Script = struct {
    bytes: []const u8 = "",
    reads: usize = 0,
    time: i64 = 0,
    stalled: bool = false,
    step_ms: i64 = 0,
    pub fn now(self: *@This()) i64 {
        return self.time;
    }
    pub fn read(self: *@This(), destination: []u8, deadline: i64) !usize {
        self.reads += 1;
        self.time += self.step_ms;
        if (self.stalled or self.time >= deadline) {
            self.time = deadline;
            return error.Timeout;
        }
        const count = @min(destination.len, self.bytes.len);
        @memcpy(destination[0..count], self.bytes[0..count]);
        self.bytes = self.bytes[count..];
        return count;
    }
};
test "game-auth boundary transport rejects bearer before zero body reads and closes" {
    if (comptime @hasDecl(http.Server, "internalExchange")) {
        const c = configuration();
        var router = initRouter(&c);
        defer router.deinit();
        var server = http.Server.init(a);
        defer server.deinit();
        try routes.register(&server, &router);
        for ([_]?[]const u8{ null, "Basic x", "Bearer ", "Bearer wrong" }) |auth| {
            var script = Script{ .stalled = true };
            var exchange = try server.internalExchange(.{ .method = .POST, .target = "/internal/game-auth/v1/cracked-login", .authorization = auth, .content_length = 999999 }, &script, &.{});
            defer exchange.result.deinit();
            try check(&exchange.result, 401);
            try std.testing.expect(exchange.close);
            try std.testing.expectEqual(@as(usize, 0), script.reads);
        }
    } else try std.testing.expect(false);
}
test "game-auth boundary transport wipes consumed source without corrupting pipeline on every exit" {
    if (comptime @hasDecl(http.Server, "internalExchange")) {
        const c = configuration();
        const bodies = [_][]const u8{ "{\"nickname\":\"Player\",\"password\":\"PASSWORD_SENTINEL\"}", "{malformed" };
        for (0..5) |mode| {
            var router = initRouter(&c);
            defer router.deinit();
            router.service.repository.allow = mode == 0;
            router.service.repository.storage_failure = mode == 2;
            router.service.repository.audit_failure = mode == 3;
            var server = http.Server.init(a);
            defer server.deinit();
            try routes.register(&server, &router);
            const body = bodies[if (mode == 4) 1 else 0];
            const source = try std.mem.concat(a, u8, &.{ body, "GET /sentinel HTTP/1.1\r\n\r\n" });
            defer a.free(source);
            var script = Script{};
            var exchange = try server.internalExchange(.{ .method = .POST, .target = "/internal/game-auth/v1/cracked-login", .authorization = "Bearer SYNTHETIC_SECRET", .content_type = "application/json", .content_length = body.len }, &script, source);
            defer exchange.result.deinit();
            try check(&exchange.result, if (mode == 2 or mode == 3) 500 else if (mode == 4) 400 else 200);
            for (source[0..body.len]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
            try std.testing.expectEqualStrings("GET /sentinel HTTP/1.1\r\n\r\n", source[body.len..]);
        }
    } else try std.testing.expect(false);
}
test "game-auth boundary transport deadlines size edges and saturated connections fail closed" {
    if (comptime @hasDecl(http.Server, "internalExchange") and @hasDecl(http, "ConnectionSlots")) {
        const c = configuration();
        var router = initRouter(&c);
        defer router.deinit();
        var server = http.Server.init(a);
        defer server.deinit();
        try routes.register(&server, &router);
        var stalled = Script{ .stalled = true };
        var timeout = try server.internalExchange(.{ .method = .POST, .target = "/internal/game-auth/v1/session-check", .authorization = "Bearer SYNTHETIC_SECRET", .content_type = "application/json", .content_length = 2 }, &stalled, &.{});
        defer timeout.result.deinit();
        try check(&timeout.result, 408);
        try std.testing.expect(timeout.close);
        var over = Script{};
        var oversized = try server.internalExchange(.{ .method = .POST, .target = "/internal/game-auth/v1/session-check", .authorization = "Bearer SYNTHETIC_SECRET", .content_type = "application/json", .content_length = 4097 }, &over, &.{});
        defer oversized.result.deinit();
        try check(&oversized.result, 400);
        try std.testing.expectEqual(@as(usize, 0), over.reads);
        var slots: http.ConnectionSlots = .{};
        for (0..16) |_| try std.testing.expect(slots.acquire());
        try std.testing.expect(!slots.acquire());
        slots.release();
        try std.testing.expect(slots.acquire());
    } else try std.testing.expect(false);
}
test "game-auth boundary headers enforce absolute deadline and byte bound" {
    if (comptime @hasDecl(http, "readBoundedHead")) {
        var buffer: [8192]u8 = undefined;
        var stalled = Script{ .stalled = true };
        try std.testing.expectError(error.Timeout, http.readBoundedHead(&stalled, &buffer, 0));
        var full: [8193]u8 = [_]u8{'x'} ** 8193;
        var large = Script{ .bytes = &full };
        try std.testing.expectError(error.HttpHeadersOversize, http.readBoundedHead(&large, &buffer, 0));
    } else try std.testing.expect(false);
}
test "game-auth boundary malformed transport attempts exhaust aggregate before reading or audit work" {
    const c = configuration();
    var router = initRouter(&c);
    defer router.deinit();
    var server = http.Server.init(a);
    defer server.deinit();
    try routes.register(&server, &router);
    for (0..121) |i| {
        var script = Script{ .stalled = true };
        var exchange = try server.internalExchange(.{ .method = .POST, .target = "/internal/game-auth/v1/session-check", .authorization = "Bearer SYNTHETIC_SECRET", .content_type = "text/plain", .content_length = 2 }, &script, &.{});
        defer exchange.result.deinit();
        try check(&exchange.result, if (i < 120) 400 else 429);
        try std.testing.expectEqual(@as(usize, 0), script.reads);
        try std.testing.expectEqualStrings("", router.service.repository.last_audit_reason);
    }
}

const Observer = struct {
    backing: std.mem.Allocator,
    frees: usize = 0,
    zeroed: usize = 0,
    watched: ?[*]u8 = null,
    watched_zero: bool = false,
    pub fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: u8, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.backing.rawAlloc(len, alignment, ra);
    }
    fn resize(_: *anyopaque, _: []u8, _: u8, _: usize, _: usize) bool {
        return false;
    }
    fn free(ctx: *anyopaque, bytes: []u8, alignment: u8, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.frees += 1;
        var all_zero = true;
        for (bytes) |b| {
            if (b != 0) all_zero = false;
        }
        if (all_zero) self.zeroed += 1;
        if (self.watched == bytes.ptr) self.watched_zero = all_zero;
        self.backing.rawFree(bytes, alignment, ra);
    }
    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .free = free };
};
test "game-auth boundary actual parser arenas zero all allocations on malformed schemas and allocation failures" {
    const Test = struct {
        fn run(backing: std.mem.Allocator) !void {
            var observer = Observer{ .backing = backing };
            var s: service.GameAuthService = .{ .allocator = observer.allocator(), .repository = .{ .allocator = a }, .limiter = service.AttemptLimiter.init(a) };
            defer s.deinit();
            const result = s.crackedLogin("test", "{\"nickname\":\"Player\",\"password\":\"PASSWORD_SENTINEL\",\"extra\":\"RAW_SENTINEL\"}");
            try std.testing.expectEqual(observer.frees, observer.zeroed);
            if (result) |unexpected| {
                a.free(unexpected);
                return error.ExpectedFailure;
            } else |err| {
                if (err == error.OutOfMemory) return err;
                try std.testing.expectEqual(error.InvalidJson, err);
                try std.testing.expect(observer.zeroed > 0);
            }
        }
    };
    try std.testing.checkAllAllocationFailures(a, Test.run, .{});
}
test "game-auth boundary transport wipes source during response allocation failure" {
    const Test = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const c = configuration();
            var router = initRouter(&c);
            defer router.deinit();
            var server = http.Server.init(a);
            defer {
                server.allocator = a;
                server.deinit();
            }
            try routes.register(&server, &router);
            server.allocator = allocator;
            router.allocator = allocator;
            router.service.allocator = allocator;
            var source = [_]u8{ '{', 'x', 'S', 'E', 'C', 'R', 'E', 'T' };
            defer {
                for (source) |byte| if (byte != 0) @panic("source not wiped on allocation failure");
            }
            var script = Script{};
            var exchange = try server.internalExchange(.{ .method = .POST, .target = "/internal/game-auth/v1/cracked-login", .authorization = "Bearer SYNTHETIC_SECRET", .content_type = "application/json", .content_length = source.len }, &script, &source);
            exchange.result.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(a, Test.run, .{});
}
test "game-auth boundary concurrent nickname admission is atomic and server scopes remain separate" {
    const Test = struct {
        fn worker(limiter: *service.AttemptLimiter, admitted: *std.atomic.Value(u32)) void {
            if (limiter.nickname("server", "PLAYER", 0) catch false) _ = admitted.fetchAdd(1, .monotonic);
        }
    };
    var limiter = service.AttemptLimiter.init(a);
    defer limiter.deinit();
    var admitted = std.atomic.Value(u32).init(0);
    var threads: [32]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Test.worker, .{ &limiter, &admitted });
    for (threads) |thread| thread.join();
    try std.testing.expectEqual(@as(u32, 5), admitted.load(.monotonic));
    try std.testing.expect(!try limiter.nickname("server", "player", 0));
    try std.testing.expect(try limiter.nickname("other", "player", 0));
}
test "game-auth boundary allow response copy is zeroed before free" {
    var observer = Observer{ .backing = a };
    const c = configuration();
    var router = initRouter(&c);
    defer router.deinit();
    router.allocator = observer.allocator();
    router.service.repository.allow = true;
    var server = http.Server.init(a);
    defer server.deinit();
    try routes.register(&server, &router);
    var result = try server.dispatch(.{ .method = .POST, .target = "/internal/game-auth/v1/cracked-login", .authorization = "Bearer SYNTHETIC_SECRET", .content_type = "application/json", .content_length = 51, .body = "{\"nickname\":\"Player\",\"password\":\"PASSWORD_SENTINEL\"}" });
    observer.watched = result.body.ptr;
    try check(&result, 200);
    result.deinit();
    try std.testing.expect(observer.watched_zero);
}
test "game-auth boundary worker lifetime stays owned through shutdown" {
    if (comptime @hasDecl(http.ConnectionSlots, "waitIdle")) {
        const Test = struct {
            fn release(slots: *http.ConnectionSlots) void {
                slots.release();
            }
        };
        var slots: http.ConnectionSlots = .{};
        try std.testing.expect(slots.acquire());
        const thread = try std.Thread.spawn(.{}, Test.release, .{&slots});
        slots.waitIdle();
        thread.join();
        try std.testing.expectEqual(@as(usize, 0), slots.active);
    } else try std.testing.expect(false);
}
test "game-auth boundary all routes hide storage and audit failures behind generic JSON" {
    const cases = [_]struct { method: std.http.Method, path: []const u8, body: []const u8 }{
        .{ .method = .GET, .path = "identity-policy?nickname=Player", .body = "" },
        .{ .method = .GET, .path = "whitelist", .body = "" },
        .{ .method = .POST, .path = "cracked-login", .body = "{\"nickname\":\"Player\",\"password\":\"PASSWORD_SENTINEL\"}" },
        .{ .method = .POST, .path = "premium-verified", .body = "{\"nickname\":\"Player\",\"mojang_uuid\":\"UUID_SENTINEL\"}" },
        .{ .method = .POST, .path = "session-check", .body = "{\"lease\":\"LEASE_SENTINEL\"}" },
    };
    for (cases) |case| for (0..2) |mode| {
        const c = configuration();
        var router = initRouter(&c);
        defer router.deinit();
        router.service.repository.storage_failure = mode == 0;
        router.service.repository.audit_failure = mode == 1;
        var server = http.Server.init(a);
        defer server.deinit();
        try routes.register(&server, &router);
        const target = try std.mem.concat(a, u8, &.{ "/internal/game-auth/v1/", case.path });
        defer a.free(target);
        var result = try server.dispatch(.{ .method = case.method, .target = target, .authorization = "Bearer SYNTHETIC_SECRET", .content_type = "application/json", .content_length = case.body.len, .body = case.body });
        defer result.deinit();
        try check(&result, 500);
        try std.testing.expectEqualStrings("{\"outcome\":\"deny\"}", result.body);
    };
}
test "game-auth boundary parser and serializer intermediate allocations wipe on denial and failures" {
    const Test = struct {
        fn run(backing: std.mem.Allocator) !void {
            for (0..4) |mode| {
                var observer = Observer{ .backing = backing };
                var s: service.GameAuthService = .{ .allocator = observer.allocator(), .repository = .{ .allocator = a }, .limiter = service.AttemptLimiter.init(a), .clock = frozenClock };
                defer s.deinit();
                s.repository.storage_failure = mode == 2;
                s.repository.audit_failure = mode == 3;
                const result = s.crackedLogin("test", "{\"nickname\":\"Player\",\"password\":\"PASSWORD_SENTINEL\"}");
                if (result) |body| {
                    defer {
                        std.crypto.utils.secureZero(u8, body);
                        observer.allocator().rawFree(body, 0, @returnAddress());
                    }
                    try std.testing.expectEqual(observer.frees, observer.zeroed);
                    try std.testing.expect(observer.zeroed > 0);
                } else |err| {
                    try std.testing.expectEqual(observer.frees, observer.zeroed);
                    if (err == error.OutOfMemory) return err;
                    try std.testing.expect(err == error.StorageUnavailable or err == error.AuditUnavailable);
                }
            }
        }
    };
    try std.testing.checkAllAllocationFailures(a, Test.run, .{});
}
test "game-auth boundary stalled authenticated body cannot hold dispatch ownership" {
    const Blocking = struct {
        entered: std.Thread.Semaphore = .{},
        finish: std.Thread.Semaphore = .{},
        status: u16 = 0,
        pub fn now(_: *@This()) i64 {
            return 0;
        }
        pub fn read(self: *@This(), _: []u8, _: i64) !usize {
            self.entered.post();
            self.finish.wait();
            return error.Timeout;
        }
        fn worker(self: *@This(), server: *http.Server) void {
            var exchange = server.internalExchange(.{ .method = .POST, .target = "/internal/game-auth/v1/session-check", .authorization = "Bearer SYNTHETIC_SECRET", .content_type = "application/json", .content_length = 2 }, self, &.{}) catch {
                self.status = 999;
                return;
            };
            self.status = exchange.result.status;
            exchange.result.deinit();
        }
    };
    const c = configuration();
    var router = initRouter(&c);
    defer router.deinit();
    var server = http.Server.init(a);
    defer server.deinit();
    try routes.register(&server, &router);
    var blocked: Blocking = .{};
    const thread = try std.Thread.spawn(.{}, Blocking.worker, .{ &blocked, &server });
    blocked.entered.wait();
    defer {
        blocked.finish.post();
        thread.join();
    }
    var result = try server.dispatch(.{ .method = .GET, .target = "/internal/game-auth/v1/identity-policy?nickname=Player", .authorization = "Bearer SYNTHETIC_SECRET" });
    defer result.deinit();
    try check(&result, 200);
}

test "game-auth boundary credential length edges preserve scope and reject suffix attacks" {
    const secret = [_]u8{'s'} ** 128;
    const raw = try std.mem.concat(a, u8, &.{ "one:", &secret, ",two:other" });
    const credentials = try config.parseGameAuthCredentials(a, raw);
    defer config.deinitGameAuthCredentials(a, credentials);
    var c = configuration();
    c.game_auth_credentials = credentials;
    var router = initRouter(&c);
    defer router.deinit();
    var server = http.Server.init(a);
    defer server.deinit();
    try routes.register(&server, &router);
    var header: [136]u8 = undefined;
    @memcpy(header[0..7], "Bearer ");
    @memcpy(header[7..135], &secret);
    header[135] = 's';
    var request = http.Request{ .method = .GET, .target = "/internal/game-auth/v1/whitelist", .authorization = header[0..135] };
    try std.testing.expect(server.authenticateHead(&request));
    try std.testing.expectEqualStrings("one", request.authenticated_server_id.?);
    request.authorization = &header;
    try std.testing.expect(!server.authenticateHead(&request));
    request.authorization = "Bearer other";
    try std.testing.expect(server.authenticateHead(&request));
    try std.testing.expectEqualStrings("two", request.authenticated_server_id.?);
    const overlong = try std.mem.concat(a, u8, &.{ "one:", &secret, "s" });
    try std.testing.expectError(error.InvalidGameAuthServerCredentials, config.parseGameAuthCredentials(a, overlong));
}
test "game-auth boundary exact premium and session schemas reject duplicates types and invalid text" {
    const cases = [_]struct { path: []const u8, body: []const u8 }{
        .{ .path = "premium-verified", .body = "{\"nickname\":\"Player\"}" },
        .{ .path = "premium-verified", .body = "{\"nickname\":\"Player\",\"mojang_uuid\":\"x\",\"password\":\"x\"}" },
        .{ .path = "premium-verified", .body = "{\"nickname\":\"Player\",\"mojang_uuid\":\"x\",\"mojang_uuid\":\"y\"}" },
        .{ .path = "premium-verified", .body = "{\"nickname\":\"Player\",\"mojang_uuid\":12}" },
        .{ .path = "session-check", .body = "{\"lease\":\"x\",\"lease\":\"y\"}" },
        .{ .path = "session-check", .body = "{\"lease\":\"\"}" },
        .{ .path = "session-check", .body = "{\"lease\":null}" },
        .{ .path = "session-check", .body = "{\"lease\":\"\\u0000\"}" },
        .{ .path = "session-check", .body = "{\"lease\":\"\xff\"}" },
        .{ .path = "session-check", .body = "{\"lease\":\"x\",\"nickname\":\"Player\"}" },
    };
    const c = configuration();
    var router = initRouter(&c);
    defer router.deinit();
    var server = http.Server.init(a);
    defer server.deinit();
    try routes.register(&server, &router);
    for (cases) |case| {
        const target = try std.mem.concat(a, u8, &.{ "/internal/game-auth/v1/", case.path });
        defer a.free(target);
        var result = try server.dispatch(.{ .method = .POST, .target = target, .authorization = "Bearer SYNTHETIC_SECRET", .content_type = "application/json", .content_length = case.body.len, .body = case.body });
        defer result.deinit();
        try check(&result, 400);
    }
}
test "game-auth boundary exhausted aggregate rejects every auth path without allocating nickname keys" {
    const c = configuration();
    var router = initRouter(&c);
    defer router.deinit();
    var server = http.Server.init(a);
    defer server.deinit();
    try routes.register(&server, &router);
    for (0..120) |_| {
        var result = try server.dispatch(.{ .method = .GET, .target = "/internal/game-auth/v1/whitelist", .authorization = "Bearer SYNTHETIC_SECRET" });
        defer result.deinit();
        try check(&result, 200);
    }
    for ([_][]const u8{ "identity-policy?nickname=Player", "whitelist", "cracked-login", "premium-verified", "session-check" }) |path| {
        const target = try std.mem.concat(a, u8, &.{ "/internal/game-auth/v1/", path });
        defer a.free(target);
        var result = try server.dispatch(.{ .method = .POST, .target = target, .authorization = "Bearer SYNTHETIC_SECRET" });
        defer result.deinit();
        try check(&result, 429);
    }
    try std.testing.expectEqual(@as(u32, 0), router.service.limiter.names.count());
    try std.testing.expectEqualStrings("whitelist_snapshot", router.service.repository.last_audit_reason);
    var limiter = service.AttemptLimiter.init(a);
    defer limiter.deinit();
    for (0..120) |_| try std.testing.expect(try limiter.server("one", 0));
    try std.testing.expect(!try limiter.server("one", 59999));
    try std.testing.expect(try limiter.server("one", 60000));
    try std.testing.expect(try limiter.server("two", 0));
}
test "game-auth boundary timeout wipes partial source" {
    const c = configuration();
    var router = initRouter(&c);
    defer router.deinit();
    var server = http.Server.init(a);
    defer server.deinit();
    try routes.register(&server, &router);
    var source = [_]u8{ 'P', 'A', 'S', 'S' };
    var script = Script{ .stalled = true };
    var exchange = try server.internalExchange(.{ .method = .POST, .target = "/internal/game-auth/v1/cracked-login", .authorization = "Bearer SYNTHETIC_SECRET", .content_type = "application/json", .content_length = 20 }, &script, &source);
    defer exchange.result.deinit();
    try check(&exchange.result, 408);
    for (source) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}
test "game-auth boundary common body reader bounds stalled and trickled chunk framing and preserves pipeline" {
    if (comptime @hasDecl(http, "readBoundedBody")) {
        var body: [65537]u8 = undefined;
        var stalled = Script{ .stalled = true };
        try std.testing.expectError(error.Timeout, http.readBoundedBody(&stalled, &.{}, 2, false, &body, 65536));
        var trickle = Script{ .bytes = "1\r\nx\r\n0\r\n\r\n", .step_ms = 500 };
        try std.testing.expectError(error.Timeout, http.readBoundedBody(&trickle, &.{}, null, true, &body, 65536));
        const source = try a.dupe(u8, "2\r\n{}\r\n0\r\n\r\nGET /sentinel HTTP/1.1\r\n\r\n");
        defer a.free(source);
        var script = Script{};
        const result = try http.readBoundedBody(&script, source, null, true, &body, 65536);
        try std.testing.expectEqualStrings("{}", body[0..result.count]);
        try std.testing.expectEqualStrings("GET /sentinel HTTP/1.1\r\n\r\n", source[result.consumed..]);
        for (source[0..result.consumed]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
        var oversized = Script{ .bytes = "10001\r\n" };
        try std.testing.expectError(error.BodyTooLarge, http.readBoundedBody(&oversized, &.{}, null, true, &body, 65536));
    } else try std.testing.expect(false);
}

const Loopback = struct {
    fn connect(listener: *std.net.Server, server: *http.Server, accepted: bool) !std.net.Stream {
        const client = try std.net.tcpConnectToAddress(listener.listen_address);
        errdefer client.close();
        const timeout = std.posix.timeval{ .tv_sec = 5, .tv_usec = 0 };
        try std.posix.setsockopt(client.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));
        const connection = try listener.accept();
        std.debug.print("game-auth listener local={any} client={any}\n", .{ listener.listen_address, connection.address });
        try std.testing.expectEqual(accepted, server.startConnection(connection));
        return client;
    }
    fn read(client: std.net.Stream, buffer: []u8, status: []const u8) ![]const u8 {
        var count: usize = 0;
        while (count < buffer.len) {
            const n = client.read(buffer[count..]) catch |err| {
                std.debug.print("game-auth listener read error={s} received={d}\n", .{ @errorName(err), count });
                if (err == error.ConnectionResetByPeer and count > 0) break;
                return err;
            };
            if (n == 0) break;
            count += n;
        }
        const bytes = buffer[0..count];
        // Closing without draining rejected input may produce TCP RST. Accept
        // that only after validating every complete Content-Length frame.
        var start: usize = 0;
        while (start < bytes.len) {
            const end = std.mem.indexOfPos(u8, bytes, start, "\r\n\r\n") orelse return error.TruncatedResponse;
            var lines = std.mem.splitSequence(u8, bytes[start..end], "\r\n");
            _ = lines.next();
            var length: ?usize = null;
            while (lines.next()) |line| {
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                if (std.ascii.eqlIgnoreCase(line[0..colon], "content-length")) length = try std.fmt.parseInt(usize, std.mem.trim(u8, line[colon + 1 ..], " "), 10);
            }
            start = end + 4 + (length orelse return error.MissingLength);
            if (start > bytes.len) return error.TruncatedResponse;
        }
        try std.testing.expect(std.mem.startsWith(u8, bytes, status));
        try std.testing.expect(std.mem.indexOf(u8, bytes, "Cache-Control: no-store") != null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "Content-Type: application/json") != null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "SYNTHETIC_SECRET") == null);
        return bytes;
    }
};

// listener runs only when explicitly selected, never during offline tests.
test "game-auth listener header-first deadlines availability limits pipeline and saturation" {
    const c = configuration();
    var router = initRouter(&c);
    defer router.deinit();
    var server = http.Server.init(a);
    defer server.deinit();
    try routes.register(&server, &router);
    const Legacy = struct {
        fn handler(_: *anyopaque, request: http.Request, _: []const u8) !http.response.Response {
            if (!std.mem.eql(u8, request.body, "{}")) return error.InvalidBody;
            return http.internalResponse(a, 200);
        }
    };
    try server.routeJson(.POST, "/legacy-json", &router, Legacy.handler);
    var listener = try (try std.net.Address.parseIp("127.0.0.1", 43081)).listen(.{ .reuse_address = true });
    defer listener.deinit();
    var buffer: [16384]u8 = undefined;
    {
        const stalled = try Loopback.connect(&listener, &server, true);
        defer stalled.close();
        try stalled.writeAll("POST /legacy-json HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 20\r\n\r\n");
        _ = try Loopback.read(stalled, &buffer, "HTTP/1.1 408");
    }
    {
        const client = try Loopback.connect(&listener, &server, true);
        defer client.close();
        try client.writeAll("POST /legacy-json HTTP/1.1\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n2\r\n{}\r\n0\r\n\r\n");
        _ = try Loopback.read(client, &buffer, "HTTP/1.1 200");
    }
    {
        const client = try Loopback.connect(&listener, &server, true);
        defer client.close();
        try client.writeAll("POST /internal/game-auth/v1/cracked-login HTTP/1.1\r\nHost: local\r\nAuthorization: Bearer wrong\r\nContent-Type: text/plain\r\nContent-Length: 999999\r\n\r\n");
        _ = try Loopback.read(client, &buffer, "HTTP/1.1 401");
    }
    {
        const stalled = try Loopback.connect(&listener, &server, true);
        defer stalled.close();
        try stalled.writeAll("POST /internal/game-auth/v1/session-check HTTP/1.1\r\nHost: local\r\nAuthorization: Bearer SYNTHETIC_SECRET\r\nContent-Type: application/json\r\nContent-Length: 20\r\n\r\n");
        var timer = try std.time.Timer.start();
        const progressing = try Loopback.connect(&listener, &server, true);
        defer progressing.close();
        try progressing.writeAll("GET /internal/game-auth/v1/identity-policy?nickname=Player HTTP/1.1\r\nAuthorization: Bearer SYNTHETIC_SECRET\r\nConnection: close\r\n\r\n");
        _ = try Loopback.read(progressing, &buffer, "HTTP/1.1 200");
        try std.testing.expect(timer.read() < 1500 * std.time.ns_per_ms);
        _ = try Loopback.read(stalled, &buffer, "HTTP/1.1 408");
    }
    {
        const client = try Loopback.connect(&listener, &server, true);
        defer client.close();
        try client.writeAll("POST /internal/game-auth/v1/session-check HTTP/1.1\r\nAuthorization: Bearer SYNTHETIC_SECRET\r\nContent-Type: application/json\r\nContent-Length: 19\r\n\r\n{\"lease\":\"invalid\"}GET /internal/game-auth/v1/whitelist HTTP/1.1\r\nAuthorization: Bearer SYNTHETIC_SECRET\r\nConnection: close\r\n\r\n");
        const bytes = try Loopback.read(client, &buffer, "HTTP/1.1 200");
        const first = std.mem.indexOf(u8, bytes, "HTTP/1.1 200").?;
        try std.testing.expect(std.mem.indexOfPos(u8, bytes, first + 1, "HTTP/1.1 200") != null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "\"outcome\":\"snapshot\"") != null);
    }
    for ([_]usize{ 4096, 4097 }) |size| {
        const client = try Loopback.connect(&listener, &server, true);
        defer client.close();
        const header = try std.fmt.allocPrint(a, "POST /internal/game-auth/v1/session-check HTTP/1.1\r\nAuthorization: Bearer SYNTHETIC_SECRET\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{size});
        defer a.free(header);
        try client.writeAll(header);
        if (size == 4096) {
            var body = [_]u8{' '} ** 4096;
            @memcpy(body[0..19], "{\"lease\":\"invalid\"}");
            try client.writeAll(&body);
        }
        _ = try Loopback.read(client, &buffer, if (size == 4096) "HTTP/1.1 200" else "HTTP/1.1 400");
    }
    for ([_]usize{ 8192, 8193 }) |size| {
        const client = try Loopback.connect(&listener, &server, true);
        defer client.close();
        const prefix = "GET /internal/game-auth/v1/whitelist HTTP/1.1\r\nAuthorization: Bearer SYNTHETIC_SECRET\r\nConnection: close\r\nX-Padding: ";
        const header = try a.alloc(u8, size);
        defer a.free(header);
        @memset(header, 'x');
        @memcpy(header[0..prefix.len], prefix);
        @memcpy(header[size - 4 ..], "\r\n\r\n");
        try client.writeAll(header);
        _ = try Loopback.read(client, &buffer, if (size == 8192) "HTTP/1.1 200" else "HTTP/1.1 400");
    }
    {
        const client = try Loopback.connect(&listener, &server, true);
        defer client.close();
        try client.writeAll("GET /internal/game-auth/v1/whitelist HTTP/1.1\r\nX-Slow: ");
        _ = try Loopback.read(client, &buffer, "HTTP/1.1 408");
    }
    server.slots.waitIdle();
    var clients: [16]std.net.Stream = undefined;
    var opened: usize = 0;
    defer for (clients[0..opened]) |client| client.close();
    for (&clients) |*client| {
        client.* = try Loopback.connect(&listener, &server, true);
        opened += 1;
        try client.writeAll("POST /legacy-json HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 20\r\n\r\n");
    }
    const excess = try Loopback.connect(&listener, &server, false);
    defer excess.close();
    try std.testing.expectEqual(@as(usize, 0), try excess.read(&buffer));
    for (clients) |client| _ = try Loopback.read(client, &buffer, "HTTP/1.1 408");
    server.slots.waitIdle();
    const recovered = try Loopback.connect(&listener, &server, true);
    defer recovered.close();
    try recovered.writeAll("GET /internal/game-auth/v1/whitelist HTTP/1.1\r\nAuthorization: Bearer SYNTHETIC_SECRET\r\nConnection: close\r\n\r\n");
    _ = try Loopback.read(recovered, &buffer, "HTTP/1.1 200");
}
