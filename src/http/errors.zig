const std = @import("std");
const response = @import("response.zig");

pub fn errorResponse(allocator: std.mem.Allocator, status: u16, code: []const u8, message: []const u8, request_id: []const u8) !response.Response {
    const body = try std.fmt.allocPrint(allocator, "{{\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\",\"request_id\":\"{s}\"}}}}", .{ code, message, request_id });
    defer allocator.free(body);
    var result = try response.Response.init(allocator, status, body);
    errdefer result.deinit();
    try result.addHeader("Content-Type", "application/json");
    return result;
}
