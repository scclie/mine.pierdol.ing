const std = @import("std");

pub const json_body_limit = 64 * 1024;

pub fn isJsonContentType(content_type: ?[]const u8) bool {
    const value = content_type orelse return false;
    const media_type = std.mem.trim(u8, value[0 .. std.mem.indexOfScalar(u8, value, ';') orelse value.len], " \t");
    return std.ascii.eqlIgnoreCase(media_type, "application/json");
}

pub fn validateJsonBody(content_type: ?[]const u8, content_length: ?u64) !void {
    if (!isJsonContentType(content_type)) return error.UnsupportedMediaType;
    const length = content_length orelse return error.BodyTooLarge;
    if (length > json_body_limit) return error.BodyTooLarge;
}
