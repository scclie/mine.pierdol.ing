const std = @import("std");
pub const errors = @import("errors.zig");
pub const response = @import("response.zig");
const request_safety = @import("request.zig");

pub const Request = struct {
    method: std.http.Method,
    target: []const u8,
    content_type: ?[]const u8 = null,
    content_length: ?u64 = null,
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

    pub fn init(allocator: std.mem.Allocator) Server {
        return .{ .allocator = allocator, .routes = std.ArrayList(Route).init(allocator) };
    }

    pub fn deinit(self: *Server) void {
        for (self.routes.items) |registered_route| self.allocator.free(registered_route.path);
        self.routes.deinit();
    }

    pub fn route(self: *Server, method: std.http.Method, path: []const u8, context: *anyopaque, handler: Handler) !void {
        try self.routes.append(.{ .method = method, .path = try self.allocator.dupe(u8, path), .context = context, .handler = handler, .expects_json = false });
    }

    pub fn routeJson(self: *Server, method: std.http.Method, path: []const u8, context: *anyopaque, handler: Handler) !void {
        try self.routes.append(.{ .method = method, .path = try self.allocator.dupe(u8, path), .context = context, .handler = handler, .expects_json = true });
    }

    pub fn dispatch(self: *Server, request: Request) !response.Response {
        var request_id_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&request_id_bytes);
        var request_id: [32]u8 = undefined;
        encodeHex(&request_id_bytes, &request_id);

        const path = request.target[0 .. std.mem.indexOfScalar(u8, request.target, '?') orelse request.target.len];
        var route_exists = false;
        for (self.routes.items) |registered_route| {
            if (!std.mem.eql(u8, registered_route.path, path)) continue;
            route_exists = true;
            if (registered_route.method != request.method) continue;
            if (registered_route.expects_json) {
                request_safety.validateJsonBody(request.content_type, request.content_length) catch |err| {
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
            var result = registered_route.handler(registered_route.context, request, &request_id) catch |err| return self.internalError(&request_id, err);
            errdefer result.deinit();
            try result.addHeader("X-Request-ID", &request_id);
            return result;
        }

        var result = if (route_exists)
            try errors.errorResponse(self.allocator, 405, "method_not_allowed", "Method not allowed.", &request_id)
        else
            try errors.errorResponse(self.allocator, 404, "not_found", "Route not found.", &request_id);
        errdefer result.deinit();
        if (route_exists) {
            var allow = std.ArrayList(u8).init(self.allocator);
            defer allow.deinit();
            for (self.routes.items) |registered_route| {
                if (!std.mem.eql(u8, registered_route.path, path)) continue;
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
            self.serveConnection(connection) catch {};
        }
    }

    fn serveConnection(self: *Server, connection: std.net.Server.Connection) !void {
        defer connection.stream.close();
        var read_buffer: [16 * 1024]u8 = undefined;
        var wire_server = std.http.Server.init(connection, &read_buffer);
        while (true) {
            var wire_request = wire_server.receiveHead() catch |err| switch (err) {
                error.HttpConnectionClosing => return,
                else => return,
            };
            var content_type: ?[]const u8 = null;
            var headers = wire_request.iterateHeaders();
            while (headers.next()) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "content-type")) content_type = header.value;
            }
            const target = try self.allocator.dupe(u8, wire_request.head.target);
            defer self.allocator.free(target);
            const saved_content_type = if (content_type) |value| try self.allocator.dupe(u8, value) else null;
            defer if (saved_content_type) |value| self.allocator.free(value);
            const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
            var expects_json = false;
            for (self.routes.items) |registered_route| {
                if (registered_route.method == wire_request.head.method and std.mem.eql(u8, registered_route.path, path)) {
                    expects_json = registered_route.expects_json;
                    break;
                }
            }
            var content_length = wire_request.head.content_length;
            var close_connection = false;
            if (expects_json) {
                if (!request_safety.isJsonContentType(saved_content_type) or (content_length orelse 0) > request_safety.json_body_limit) {
                    close_connection = true;
                } else {
                    const reader = try wire_request.reader();
                    var body: [request_safety.json_body_limit + 1]u8 = undefined;
                    var count: usize = 0;
                    while (count < body.len) {
                        const n = try reader.read(body[count..]);
                        if (n == 0) break;
                        count += n;
                    }
                    content_length = count;
                    if (count > request_safety.json_body_limit) close_connection = true;
                }
            }
            var result = try self.dispatch(.{
                .method = wire_request.head.method,
                .target = target,
                .content_type = saved_content_type,
                .content_length = content_length,
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
