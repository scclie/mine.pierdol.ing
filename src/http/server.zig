const std = @import("std");
pub const errors = @import("errors.zig");
pub const response = @import("response.zig");
const request_safety = @import("request.zig");

// Private auth payloads contain at most two short strings. 4 KiB permits
// existing passwords while bounding copies. Headers allow 8 KiB (incl. bearer).
// Absolute stage deadlines stop trickle uploads; 16 workers cap stack/socket use.
pub const Limits = struct {
    pub const header_bytes = 8192;
    pub const body_bytes = 4096;
    pub const header_ms = 2000;
    pub const body_ms = 2000;
    pub const connections = 16;
};

pub fn isInternal(target: []const u8) bool {
    return std.mem.startsWith(u8, target, "/internal/game-auth/v1/");
}

pub fn internalResponse(allocator: std.mem.Allocator, status: u16) !response.Response {
    var result = try response.Response.init(allocator, status, "{\"outcome\":\"deny\"}");
    errdefer result.deinit();
    try result.addHeader("Content-Type", "application/json");
    try result.addHeader("Cache-Control", "no-store");
    return result;
}

pub const ConnectionSlots = struct {
    mutex: std.Thread.Mutex = .{},
    idle: std.Thread.Condition = .{},
    active: usize = 0,
    pub fn acquire(self: *@This()) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.active == Limits.connections) return false;
        self.active += 1;
        return true;
    }
    pub fn release(self: *@This()) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.active > 0);
        self.active -= 1;
        if (self.active == 0) self.idle.broadcast();
    }
    pub fn waitIdle(self: *@This()) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.active != 0) self.idle.wait(&self.mutex);
    }
};

pub const HeadRange = struct { end: usize, buffered: usize };
// Shared production state machine, exercised by scripted offline I/O. Read only
// through the header terminator: unauthenticated bodies are never requested.
pub fn readBoundedHead(io: anytype, buffer: []u8, initial: usize) !HeadRange {
    const deadline = io.now() + Limits.header_ms;
    var parser: std.http.HeadParser = .{};
    if (initial > 0) {
        const end = parser.feed(buffer[0..initial]);
        if (parser.state == .finished) return .{ .end = end, .buffered = initial };
    }
    var count = initial;
    while (count < @min(buffer.len, Limits.header_bytes)) {
        if (io.now() >= deadline) return error.Timeout;
        const n = try io.read(buffer[count .. count + 1], deadline);
        if (n == 0) return error.HttpConnectionClosing;
        const end = parser.feed(buffer[count .. count + n]);
        count += n;
        if (parser.state == .finished) return .{ .end = count - n + end, .buffered = count };
    }
    return error.HttpHeadersOversize;
}

pub const BodyRange = struct { count: usize, consumed: usize };

// The shared listener must not let unrelated JSON uploads retain all auth
// workers. Preserve the existing 64 KiB/chunked support, but put *every* framing
// read under one absolute deadline. Chunk metadata has a separate 8 KiB budget.
pub fn readBoundedBody(io: anytype, buffered: []u8, length: ?u64, chunked: bool, destination: []u8, limit: usize) !BodyRange {
    const Input = struct {
        source: []u8,
        consumed: usize = 0,
        metadata: usize = 0,
        io: @TypeOf(io),
        deadline: i64,
        fn pull(self: *@This(), bytes: []u8) !usize {
            if (self.io.now() >= self.deadline) return error.Timeout;
            if (self.consumed < self.source.len) {
                const count = @min(bytes.len, self.source.len - self.consumed);
                const source = self.source[self.consumed..][0..count];
                @memcpy(bytes[0..count], source);
                std.crypto.utils.secureZero(u8, source);
                self.consumed += count;
                return count;
            }
            return self.io.read(bytes, self.deadline);
        }
        fn exact(self: *@This(), bytes: []u8) !void {
            var count: usize = 0;
            while (count < bytes.len) {
                const n = try self.pull(bytes[count..]);
                if (n == 0) return error.InvalidBody;
                count += n;
            }
        }
        fn byte(self: *@This()) !u8 {
            var value: [1]u8 = undefined;
            defer std.crypto.utils.secureZero(u8, &value);
            try self.exact(&value);
            self.metadata += 1;
            if (self.metadata > Limits.header_bytes) return error.InvalidBody;
            return value[0];
        }
        fn line(self: *@This(), buffer: []u8) ![]const u8 {
            var count: usize = 0;
            while (true) {
                const value = try self.byte();
                if (value == '\r') {
                    if (try self.byte() != '\n') return error.InvalidBody;
                    return buffer[0..count];
                }
                if (value == '\n' or count == buffer.len) return error.InvalidBody;
                buffer[count] = value;
                count += 1;
            }
        }
    };
    var input = Input{ .source = buffered, .io = io, .deadline = io.now() + Limits.body_ms };
    const maximum = @min(limit, destination.len);
    if (!chunked) {
        const size = length orelse 0;
        if (size > maximum) return error.BodyTooLarge;
        try input.exact(destination[0..@intCast(size)]);
        return .{ .count = @intCast(size), .consumed = input.consumed };
    }
    var line_buffer: [1024]u8 = undefined;
    defer std.crypto.utils.secureZero(u8, &line_buffer);
    var count: usize = 0;
    while (true) {
        const line = try input.line(&line_buffer);
        const number = line[0 .. std.mem.indexOfScalar(u8, line, ';') orelse line.len];
        if (number.len == 0) return error.InvalidBody;
        for (number) |value| if (!std.ascii.isHex(value)) return error.InvalidBody;
        const size = std.fmt.parseInt(usize, number, 16) catch return error.InvalidBody;
        if (size == 0) {
            while ((try input.line(&line_buffer)).len != 0) {}
            return .{ .count = count, .consumed = input.consumed };
        }
        if (size > maximum - count) return error.BodyTooLarge;
        try input.exact(destination[count .. count + size]);
        count += size;
        if (try input.byte() != '\r' or try input.byte() != '\n') return error.InvalidBody;
    }
}

const SocketIO = struct {
    stream: std.net.Stream,
    timer: std.time.Timer,
    fn now(self: *@This()) i64 {
        return @intCast(self.timer.read() / std.time.ns_per_ms);
    }
    fn read(self: *@This(), buffer: []u8, deadline: i64) !usize {
        while (true) {
            const remaining = deadline - self.now();
            if (remaining <= 0) return error.Timeout;
            var descriptors = [_]std.posix.pollfd{.{ .fd = self.stream.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            if (try std.posix.poll(&descriptors, @intCast(remaining)) == 0) return error.Timeout;
            return self.stream.read(buffer);
        }
    }
};

pub const Request = struct {
    method: std.http.Method,
    target: []const u8,
    content_type: ?[]const u8 = null,
    content_length: ?u64 = null,
    body: []const u8 = "",
    cookie: ?[]const u8 = null,
    csrf_token: ?[]const u8 = null,
    authorization: ?[]const u8 = null,
    authenticated_server_id: ?[]const u8 = null,
    unsupported_framing: bool = false,
};

pub const Handler = *const fn (context: *anyopaque, request: Request, request_id: []const u8) anyerror!response.Response;

const Route = struct {
    method: std.http.Method,
    path: []u8,
    handler: Handler,
    context: *anyopaque,
    expects_json: bool,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    routes: std.ArrayList(Route),
    internal_auth: ?struct { context: *anyopaque, check: *const fn (*anyopaque, ?[]const u8) ?[]const u8 } = null,
    internal_admission: ?struct { context: *anyopaque, take: *const fn (*anyopaque, []const u8) anyerror!void } = null,
    // One libpq connection is shared by all routers. Serialize complete handler
    // transactions, NOT socket reads; stalled clients never hold this lock.
    dispatch_mutex: std.Thread.Mutex = .{},
    slots: ConnectionSlots = .{},

    pub const Exchange = struct { result: response.Response, consumed: usize = 0, close: bool = false };

    // Transport alone owns/wipes mutable source ranges. Never constCast a
    // handler's body, which may be borrowed or share pipelined request storage.
    pub fn internalExchange(self: *Server, input: Request, io: anytype, buffered: []u8) !Exchange {
        var request = input;
        if (!self.authenticateHead(&request)) return .{ .result = try internalResponse(self.allocator, 401), .close = true };
        self.admitInternal(request.authenticated_server_id.?) catch |err| return .{ .result = try internalResponse(self.allocator, if (err == error.RateLimited) 429 else 500), .close = true };
        if (request.unsupported_framing) return .{ .result = try internalResponse(self.allocator, 400), .close = true };
        const length = request.content_length orelse 0;
        if (length > Limits.body_bytes or (request.method == .POST and (!request_safety.isJsonContentType(request.content_type) or request.content_length == null)))
            return .{ .result = try internalResponse(self.allocator, 400), .close = true };
        if (request.method != .POST and length != 0) return .{ .result = try internalResponse(self.allocator, 400), .close = true };
        var body: [Limits.body_bytes]u8 = undefined;
        defer std.crypto.utils.secureZero(u8, &body);
        const consumed = @min(buffered.len, length);
        @memcpy(body[0..consumed], buffered[0..consumed]);
        std.crypto.utils.secureZero(u8, buffered[0..consumed]);
        var count: usize = consumed;
        const deadline = io.now() + Limits.body_ms;
        while (count < length) {
            if (io.now() >= deadline) return .{ .result = try internalResponse(self.allocator, 408), .consumed = consumed, .close = true };
            const n = io.read(body[count..@intCast(length)], deadline) catch |err| return .{ .result = try internalResponse(self.allocator, if (err == error.Timeout) 408 else 400), .consumed = consumed, .close = true };
            if (n == 0) return .{ .result = try internalResponse(self.allocator, 400), .consumed = consumed, .close = true };
            count += n;
        }
        request.body = body[0..count];
        const result = self.dispatchAdmitted(request, true) catch return .{ .result = try internalResponse(self.allocator, 500), .consumed = consumed, .close = true };
        // Even errors own a no-store JSON response. Wipe body before returning.
        return .{ .result = result, .consumed = consumed, .close = result.status != 200 };
    }

    pub fn setInternalAuthentication(self: *Server, context: *anyopaque, check: *const fn (*anyopaque, ?[]const u8) ?[]const u8) void {
        self.internal_auth = .{ .context = context, .check = check };
    }

    pub fn setInternalAdmission(self: *Server, context: *anyopaque, take: *const fn (*anyopaque, []const u8) anyerror!void) void {
        self.internal_admission = .{ .context = context, .take = take };
    }

    fn admitInternal(self: *Server, server_id: []const u8) !void {
        const admission = self.internal_admission orelse return error.Unavailable;
        try admission.take(admission.context, server_id);
    }

    pub fn authenticateHead(self: *Server, request: *Request) bool {
        request.authenticated_server_id = null;
        if (!isInternal(request.target)) return true;
        const auth = self.internal_auth orelse return false;
        request.authenticated_server_id = auth.check(auth.context, request.authorization);
        return request.authenticated_server_id != null;
    }

    pub fn init(allocator: std.mem.Allocator) Server {
        return .{ .allocator = allocator, .routes = std.ArrayList(Route).init(allocator) };
    }

    pub fn deinit(self: *Server) void {
        self.slots.waitIdle();
        for (self.routes.items) |registered_route| self.allocator.free(registered_route.path);
        self.routes.deinit();
    }

    pub fn route(self: *Server, method: std.http.Method, path: []const u8, context: *anyopaque, handler: Handler) !void {
        try self.routes.append(.{ .method = method, .path = try self.allocator.dupe(u8, path), .context = context, .handler = handler, .expects_json = false });
    }

    pub fn routeJson(self: *Server, method: std.http.Method, path: []const u8, context: *anyopaque, handler: Handler) !void {
        try self.routes.append(.{ .method = method, .path = try self.allocator.dupe(u8, path), .context = context, .handler = handler, .expects_json = true });
    }

    pub fn dispatch(self: *Server, input: Request) !response.Response {
        return self.dispatchAdmitted(input, false);
    }

    fn dispatchAdmitted(self: *Server, input: Request, admitted: bool) !response.Response {
        var request = input;
        const internal = isInternal(request.target);
        if (!self.authenticateHead(&request)) return internalResponse(self.allocator, 401);
        if (internal and !admitted) self.admitInternal(request.authenticated_server_id.?) catch |err| return internalResponse(self.allocator, if (err == error.RateLimited) 429 else 500);
        self.dispatch_mutex.lock();
        defer self.dispatch_mutex.unlock();
        var request_id_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&request_id_bytes);
        var request_id: [32]u8 = undefined;
        encodeHex(&request_id_bytes, &request_id);

        const path = request.target[0 .. std.mem.indexOfScalar(u8, request.target, '?') orelse request.target.len];
        var route_exists = false;
        for (self.routes.items) |registered_route| {
            if (!matchesPath(registered_route.path, path)) continue;
            route_exists = true;
            if (registered_route.method != request.method) continue;
            if (registered_route.expects_json) {
                if (internal and (!request_safety.isJsonContentType(request.content_type) or request.body.len > Limits.body_bytes or (request.content_length orelse request.body.len) > Limits.body_bytes)) return internalResponse(self.allocator, 400);
                const actual_length: ?u64 = if (request.content_length) |length| @max(length, request.body.len) else null;
                request_safety.validateJsonBody(request.content_type, actual_length) catch |err| {
                    if (internal) return internalResponse(self.allocator, 400);
                    const status: u16 = switch (err) {
                        error.UnsupportedMediaType => 415,
                        error.BodyTooLarge => 413,
                    };
                    const code = if (status == 415) "unsupported_media_type" else "request_body_too_large";
                    var rejected = try errors.errorResponse(self.allocator, status, code, "Invalid JSON request body.", &request_id);
                    errdefer rejected.deinit();
                    try rejected.addHeader("X-Request-ID", &request_id);
                    return rejected;
                };
            }
            var result = registered_route.handler(registered_route.context, request, &request_id) catch |err| {
                if (internal) return internalResponse(self.allocator, 500);
                return self.internalError(&request_id, err);
            };
            errdefer result.deinit();
            try result.addHeader("X-Request-ID", &request_id);
            return result;
        }

        if (internal) return internalResponse(self.allocator, if (route_exists) 405 else 404);
        var result = if (route_exists)
            try errors.errorResponse(self.allocator, 405, "method_not_allowed", "Method not allowed.", &request_id)
        else
            try errors.errorResponse(self.allocator, 404, "not_found", "Route not found.", &request_id);
        errdefer result.deinit();
        if (route_exists) {
            var allow = std.ArrayList(u8).init(self.allocator);
            defer allow.deinit();
            for (self.routes.items) |registered_route| {
                if (!matchesPath(registered_route.path, path)) continue;
                if (allow.items.len != 0) try allow.appendSlice(", ");
                try allow.appendSlice(@tagName(registered_route.method));
            }
            try result.addHeader("Allow", allow.items);
        }
        try result.addHeader("X-Request-ID", &request_id);
        return result;
    }

    fn internalError(self: *Server, request_id: []const u8, _: anyerror) !response.Response {
        var result = try errors.errorResponse(self.allocator, 500, "internal_error", "An internal error occurred.", request_id);
        errdefer result.deinit();
        try result.addHeader("X-Request-ID", request_id);
        return result;
    }

    pub fn serve(self: *Server, listen_address: []const u8) !void {
        const address = try parseListenAddress(listen_address);
        var listener = try address.listen(.{ .reuse_address = true });
        defer listener.deinit();
        while (true) {
            const connection = try listener.accept();
            _ = self.startConnection(connection);
        }
    }

    // Takes ownership even on saturation/spawn failure. Also supports callers
    // embedding this listener in an existing local accept loop.
    pub fn startConnection(self: *Server, connection: std.net.Server.Connection) bool {
        if (!self.slots.acquire()) {
            connection.stream.close();
            return false;
        }
        const worker = std.Thread.spawn(.{}, workerMain, .{ self, connection }) catch {
            self.slots.release();
            connection.stream.close();
            return false;
        };
        worker.detach();
        return true;
    }

    fn workerMain(self: *Server, connection: std.net.Server.Connection) void {
        defer self.slots.release();
        self.serveConnection(connection) catch {};
    }

    fn serveConnection(self: *Server, connection: std.net.Server.Connection) !void {
        defer connection.stream.close();
        var read_buffer: [Limits.header_bytes]u8 = undefined;
        defer std.crypto.utils.secureZero(u8, &read_buffer);
        var wire_server = std.http.Server.init(connection, &read_buffer);
        var io = SocketIO{ .stream = connection.stream, .timer = try std.time.Timer.start() };
        // Bound response writes too, so a non-reading peer cannot retain a slot.
        const write_timeout = std.posix.timeval{ .tv_sec = 2, .tv_usec = 0 };
        try std.posix.setsockopt(connection.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&write_timeout));
        while (true) {
            if (wire_server.next_request_start > 0) {
                const remaining = wire_server.read_buffer_len - wire_server.next_request_start;
                std.mem.copyForwards(u8, read_buffer[0..remaining], read_buffer[wire_server.next_request_start..wire_server.read_buffer_len]);
                std.crypto.utils.secureZero(u8, read_buffer[remaining..]);
                wire_server.read_buffer_len = remaining;
                wire_server.next_request_start = 0;
            }
            const range = readBoundedHead(&io, &read_buffer, wire_server.read_buffer_len) catch |err| {
                if (err != error.HttpConnectionClosing) try connection.stream.writeAll(if (err == error.Timeout)
                    "HTTP/1.1 408 Request Timeout\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nContent-Length: 18\r\nConnection: close\r\n\r\n{\"outcome\":\"deny\"}"
                else
                    "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nContent-Length: 18\r\nConnection: close\r\n\r\n{\"outcome\":\"deny\"}");
                return;
            };
            wire_server.read_buffer_len = range.buffered;
            wire_server.state = .received_head;
            var wire_request: std.http.Server.Request = .{ .server = &wire_server, .head_end = range.end, .head = std.http.Server.Request.Head.parse(read_buffer[0..range.end]) catch {
                try connection.stream.writeAll("HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nContent-Length: 18\r\nConnection: close\r\n\r\n{\"outcome\":\"deny\"}");
                return;
            }, .reader_state = undefined };
            var content_type: ?[]const u8 = null;
            var cookie: ?[]const u8 = null;
            var csrf_token: ?[]const u8 = null;
            var authorization: ?[]const u8 = null;
            var authorization_count: usize = 0;
            var headers = wire_request.iterateHeaders();
            while (headers.next()) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "content-type")) content_type = header.value;
                if (std.ascii.eqlIgnoreCase(header.name, "cookie")) cookie = header.value;
                if (std.ascii.eqlIgnoreCase(header.name, "x-csrf-token")) csrf_token = header.value;
                if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
                    authorization = header.value;
                    authorization_count += 1;
                }
            }
            if (authorization_count > 1) authorization = null;
            if (isInternal(wire_request.head.target)) {
                const input = Request{ .method = wire_request.head.method, .target = wire_request.head.target, .content_type = content_type, .content_length = wire_request.head.content_length, .authorization = authorization, .unsupported_framing = wire_request.head.transfer_encoding != .none or wire_request.head.transfer_compression != .identity or wire_request.head.expect != null };
                var exchange = try self.internalExchange(input, &io, read_buffer[range.end..range.buffered]);
                defer exchange.result.deinit();
                defer std.crypto.utils.secureZero(u8, exchange.result.body);
                wire_server.next_request_start = range.end + exchange.consumed;
                wire_server.state = .ready;
                // respond() must not drain rejected/unfinished input.
                wire_request.head.expect = null;
                var wire_headers: [32]std.http.Header = undefined;
                for (exchange.result.headers.items, 0..) |header, index| wire_headers[index] = .{ .name = header.name, .value = header.value };
                try wire_request.respond(exchange.result.body, .{ .status = @enumFromInt(exchange.result.status), .extra_headers = wire_headers[0..exchange.result.headers.items.len], .keep_alive = !exchange.close });
                if (exchange.close or !wire_request.head.keep_alive) return;
                // Header credentials are no longer needed; preserve next frame.
                std.crypto.utils.secureZero(u8, read_buffer[0..range.end]);
                continue;
            }
            const target = try self.allocator.dupe(u8, wire_request.head.target);
            defer self.allocator.free(target);
            const saved_content_type = if (content_type) |value| try self.allocator.dupe(u8, value) else null;
            defer if (saved_content_type) |value| self.allocator.free(value);
            const saved_cookie = if (cookie) |value| try self.allocator.dupe(u8, value) else null;
            defer if (saved_cookie) |value| {
                std.crypto.utils.secureZero(u8, value);
                self.allocator.free(value);
            };
            const saved_csrf = if (csrf_token) |value| try self.allocator.dupe(u8, value) else null;
            defer if (saved_csrf) |value| {
                std.crypto.utils.secureZero(u8, value);
                self.allocator.free(value);
            };
            const saved_authorization = if (authorization) |value| try self.allocator.dupe(u8, value) else null;
            defer if (saved_authorization) |value| {
                std.crypto.utils.secureZero(u8, value);
                self.allocator.free(value);
            };
            const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
            var expects_json = false;
            for (self.routes.items) |registered_route| {
                if (registered_route.method == wire_request.head.method and matchesPath(registered_route.path, path)) {
                    expects_json = registered_route.expects_json;
                    break;
                }
            }
            var content_length = wire_request.head.content_length;
            var close_connection = false;
            var body: [request_safety.json_body_limit + 1]u8 = undefined;
            defer std.crypto.utils.secureZero(u8, &body);
            var count: usize = 0;
            if (!expects_json and ((content_length orelse 0) != 0 or wire_request.head.transfer_encoding != .none)) close_connection = true;
            if (expects_json) {
                if (!request_safety.isJsonContentType(saved_content_type) or (content_length orelse 0) > request_safety.json_body_limit) {
                    close_connection = true;
                } else {
                    if (wire_request.head.expect) |expect| {
                        if (!std.mem.eql(u8, expect, "100-continue")) return error.InvalidBody;
                        try connection.stream.writeAll("HTTP/1.1 100 Continue\r\n\r\n");
                        wire_request.head.expect = null;
                    }
                    const read = readBoundedBody(&io, read_buffer[range.end..range.buffered], content_length, wire_request.head.transfer_encoding == .chunked, &body, request_safety.json_body_limit) catch |err| {
                        var rejected = try internalResponse(self.allocator, if (err == error.Timeout) 408 else if (err == error.BodyTooLarge) 413 else 400);
                        defer rejected.deinit();
                        wire_server.state = .ready;
                        wire_request.head.expect = null;
                        var rejected_headers: [32]std.http.Header = undefined;
                        for (rejected.headers.items, 0..) |header, index| rejected_headers[index] = .{ .name = header.name, .value = header.value };
                        try wire_request.respond(rejected.body, .{ .status = @enumFromInt(rejected.status), .extra_headers = rejected_headers[0..rejected.headers.items.len], .keep_alive = false });
                        return;
                    };
                    count = read.count;
                    wire_server.next_request_start = range.end + read.consumed;
                    wire_server.state = .ready;
                    content_length = count;
                    if (count > request_safety.json_body_limit) close_connection = true;
                }
            }
            var result = try self.dispatch(.{
                .method = wire_request.head.method,
                .target = target,
                .content_type = saved_content_type,
                .content_length = content_length,
                .body = body[0..count],
                .cookie = saved_cookie,
                .csrf_token = saved_csrf,
                .authorization = saved_authorization,
            });
            defer result.deinit();
            var wire_headers: [32]std.http.Header = undefined;
            for (result.headers.items, 0..) |header, index| wire_headers[index] = .{ .name = header.name, .value = header.value };
            if (close_connection) wire_request.head.expect = null;
            try wire_request.respond(result.body, .{
                .status = @enumFromInt(result.status),
                .extra_headers = wire_headers[0..result.headers.items.len],
                .keep_alive = !close_connection,
            });
            if (close_connection or !wire_request.head.keep_alive) return;
        }
    }
};

fn matchesPath(pattern: []const u8, path: []const u8) bool {
    var expected = std.mem.splitScalar(u8, pattern, '/');
    var actual = std.mem.splitScalar(u8, path, '/');
    while (expected.next()) |segment| {
        const value = actual.next() orelse return false;
        if (segment.len > 0 and segment[0] == ':') {
            if (value.len == 0) return false;
        } else if (!std.mem.eql(u8, segment, value)) return false;
    }
    return actual.next() == null;
}

fn parseListenAddress(value: []const u8) !std.net.Address {
    const separator = std.mem.lastIndexOfScalar(u8, value, ':') orelse return error.InvalidListenAddress;
    const host = value[0..separator];
    const port = std.fmt.parseInt(u16, value[separator + 1 ..], 10) catch return error.InvalidListenAddress;
    return std.net.Address.parseIp(host, port) catch error.InvalidListenAddress;
}

test "wire JSON accepts a bounded chunked body before dispatch" {
    const Test = struct {
        fn handler(context: *anyopaque, _: Request, _: []const u8) !response.Response {
            const called: *bool = @ptrCast(@alignCast(context));
            called.* = true;
            return response.Response.init(std.heap.page_allocator, 204, "");
        }
        fn serveOne(server: *Server, listener: *std.net.Server) void {
            const connection = listener.accept() catch return;
            server.serveConnection(connection) catch {};
        }
    };
    var server = Server.init(std.heap.page_allocator);
    defer server.deinit();
    var called = false;
    try server.routeJson(.POST, "/json", &called, Test.handler);
    try server.route(.GET, "/api/v1/auth/discord", &called, Test.handler);
    var listener = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{});
    defer listener.deinit();
    const thread = try std.Thread.spawn(.{}, Test.serveOne, .{ &server, &listener });
    const client = try std.net.tcpConnectToAddress(listener.listen_address);
    defer client.close();
    try client.writeAll("POST /json HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n2\r\n{}\r\n0\r\n\r\n");
    var buffer: [1024]u8 = undefined;
    const count = try client.read(&buffer);
    thread.join();
    try std.testing.expect(count >= 12);
    try std.testing.expectEqualStrings("HTTP/1.1 204", buffer[0..12]);
    try std.testing.expect(called);
    called = false;
    const get_thread = try std.Thread.spawn(.{}, Test.serveOne, .{ &server, &listener });
    const get_client = try std.net.tcpConnectToAddress(listener.listen_address);
    defer get_client.close();
    try get_client.writeAll("GET /api/v1/auth/discord HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    const get_count = try get_client.read(&buffer);
    get_thread.join();
    try std.testing.expect(get_count >= 12);
    try std.testing.expectEqualStrings("HTTP/1.1 204", buffer[0..12]);
    try std.testing.expect(called);
}

test "wire JSON rejects invalid media type and oversized streamed bodies" {
    const Test = struct {
        fn handler(context: *anyopaque, _: Request, _: []const u8) !response.Response {
            const called: *bool = @ptrCast(@alignCast(context));
            called.* = true;
            return response.Response.init(std.heap.page_allocator, 204, "");
        }
        fn serveOne(server: *Server, listener: *std.net.Server) void {
            const connection = listener.accept() catch return;
            server.serveConnection(connection) catch {};
        }
    };
    var server = Server.init(std.heap.page_allocator);
    defer server.deinit();
    var called = false;
    try server.routeJson(.POST, "/json", &called, Test.handler);
    try server.route(.GET, "/api/v1/auth/discord", &called, Test.handler);
    var listener = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{});
    defer listener.deinit();
    for (0..4) |case| {
        const thread = try std.Thread.spawn(.{}, Test.serveOne, .{ &server, &listener });
        const client = try std.net.tcpConnectToAddress(listener.listen_address);
        if (case == 0) {
            try client.writeAll("POST /json HTTP/1.1\r\nHost: localhost\r\nContent-Type: text/plain\r\nContent-Length: 9999999\r\n\r\n");
        } else if (case == 1) {
            try client.writeAll("POST /json HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 65537\r\n\r\n");
        } else if (case == 2) {
            try client.writeAll("POST /json HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\n{}");
        } else {
            try client.writeAll("POST /json HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n10001\r\n");
            const body = [_]u8{'x'} ** 65537;
            try client.writeAll(&body);
        }
        var buffer: [1024]u8 = undefined;
        const n = try client.read(&buffer);
        try std.testing.expect(n >= 12);
        try std.testing.expectEqualStrings(if (case == 0 or case == 2) "HTTP/1.1 415" else "HTTP/1.1 413", buffer[0..12]);
        client.close();
        thread.join();
    }
    try std.testing.expect(!called);
}

test "dispatch cleans up sensitive response when request ID allocation fails" {
    const Test = struct {
        fn handler(context: *anyopaque, _: Request, _: []const u8) !response.Response {
            const allocator: *std.mem.Allocator = @ptrCast(@alignCast(context));
            var result = try response.Response.init(allocator.*, 302, "");
            errdefer result.deinit();
            try result.addSensitiveHeader("Location", "state=secret");
            return result;
        }
        fn run(allocator: std.mem.Allocator) !void {
            var server = Server.init(std.testing.allocator);
            defer {
                server.allocator = std.testing.allocator;
                server.deinit();
            }
            var response_allocator = allocator;
            try server.route(.GET, "/login", &response_allocator, handler);
            server.allocator = allocator;
            var result = try server.dispatch(.{ .method = .GET, .target = "/login" });
            result.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Test.run, .{});
}

fn encodeHex(source: []const u8, destination: []u8) void {
    const alphabet = "0123456789abcdef";
    for (source, 0..) |byte, index| {
        destination[index * 2] = alphabet[byte >> 4];
        destination[index * 2 + 1] = alphabet[byte & 0x0f];
    }
}
