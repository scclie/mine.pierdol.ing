const std = @import("std");

pub const Header = struct {
    name: []const u8,
    value: []u8,
    sensitive: bool = false,
};

pub const Response = struct {
    allocator: std.mem.Allocator,
    status: u16,
    body: []u8,
    headers: std.ArrayList(Header),

    pub fn init(allocator: std.mem.Allocator, status: u16, body: []const u8) !Response {
        return .{
            .allocator = allocator,
            .status = status,
            .body = try allocator.dupe(u8, body),
            .headers = std.ArrayList(Header).init(allocator),
        };
    }

    pub fn deinit(self: *Response) void {
        for (self.headers.items) |stored_header| {
            if (stored_header.sensitive) std.crypto.utils.secureZero(u8, stored_header.value);
            self.allocator.free(stored_header.value);
        }
        self.headers.deinit();
        self.allocator.free(self.body);
    }

    pub fn addHeader(self: *Response, name: []const u8, value: []const u8) !void {
        const owned = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned);
        try self.headers.append(.{ .name = name, .value = owned });
    }

    pub fn addSensitiveHeader(self: *Response, name: []const u8, value: []const u8) !void {
        const owned = try self.allocator.dupe(u8, value);
        errdefer {
            std.crypto.utils.secureZero(u8, owned);
            self.allocator.free(owned);
        }
        try self.headers.append(.{ .name = name, .value = owned, .sensitive = true });
    }

    pub fn header(self: *const Response, name: []const u8) ?[]const u8 {
        for (self.headers.items) |stored_header| {
            if (std.ascii.eqlIgnoreCase(stored_header.name, name)) return stored_header.value;
        }
        return null;
    }
};

test "sensitive header values are cleared before release while ordinary headers remain unchanged" {
    // debug and ReleaseSafe modes poison freed allocations before the allocator sees them.
    if (@import("builtin").mode != .ReleaseFast and @import("builtin").mode != .ReleaseSmall) return error.SkipZigTest;
    const Observer = struct {
        backing: std.mem.Allocator,
        sensitive_ptr: ?[*]const u8 = null,
        cookie_ptr: ?[*]const u8 = null,
        ordinary_ptr: ?[*]const u8 = null,
        sensitive_zeroed: bool = false,
        cookie_zeroed: bool = false,
        ordinary_unchanged: bool = false,
        fn alloc(ctx: *anyopaque, len: usize, alignment: u8, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.backing.rawAlloc(len, alignment, ra);
        }
        fn resize(ctx: *anyopaque, buffer: []u8, alignment: u8, len: usize, ra: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.backing.rawResize(buffer, alignment, len, ra);
        }
        fn free(ctx: *anyopaque, buffer: []u8, alignment: u8, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.sensitive_ptr != null and buffer.ptr == self.sensitive_ptr.?) {
                self.sensitive_zeroed = true;
                for (buffer) |byte| if (byte != 0) {
                    self.sensitive_zeroed = false;
                };
            }
            if (self.cookie_ptr != null and buffer.ptr == self.cookie_ptr.?) {
                self.cookie_zeroed = true;
                for (buffer) |byte| if (byte != 0) {
                    self.cookie_zeroed = false;
                };
            }
            if (self.ordinary_ptr != null and buffer.ptr == self.ordinary_ptr.?) self.ordinary_unchanged = std.mem.eql(u8, buffer, "ordinary-value");
            self.backing.rawFree(buffer, alignment, ra);
        }
        const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .free = free };
    };
    var observer = Observer{ .backing = std.testing.allocator };
    const allocator = std.mem.Allocator{ .ptr = &observer, .vtable = &Observer.vtable };
    var result = try Response.init(allocator, 302, "");
    try result.addSensitiveHeader("Location", "state=secret");
    try result.addSensitiveHeader("Set-Cookie", "mine_session=secret");
    try result.addHeader("X-Ordinary", "ordinary-value");
    try std.testing.expectEqualStrings("state=secret", result.header("Location").?);
    try std.testing.expectEqualStrings("mine_session=secret", result.header("Set-Cookie").?);
    try std.testing.expectEqualStrings("ordinary-value", result.header("X-Ordinary").?);
    observer.sensitive_ptr = result.headers.items[0].value.ptr;
    observer.cookie_ptr = result.headers.items[1].value.ptr;
    observer.ordinary_ptr = result.headers.items[2].value.ptr;
    result.deinit();
    try std.testing.expect(observer.sensitive_zeroed);
    try std.testing.expect(observer.cookie_zeroed);
    try std.testing.expect(observer.ordinary_unchanged);
}

pub fn redirect(allocator: std.mem.Allocator, location: []const u8) !Response {
    var result = try Response.init(allocator, 302, "");
    errdefer result.deinit();
    try result.addHeader("Location", location);
    return result;
}
