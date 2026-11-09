const std = @import("std");

/// owns both values copies are independent.
pub const CanonicalNickname = struct {
    display_bytes: [16]u8 = [_]u8{0} ** 16,
    canonical_bytes: [16]u8 = [_]u8{0} ** 16,
    len: u8,

    pub fn display(self: *const CanonicalNickname) []const u8 {
        return self.display_bytes[0..self.len];
    }

    pub fn canonical(self: *const CanonicalNickname) []const u8 {
        return self.canonical_bytes[0..self.len];
    }
};

pub fn validateNickname(raw: []const u8) error{InvalidNickname}!CanonicalNickname {
    if (raw.len < 3 or raw.len > 16) return error.InvalidNickname;

    var result = CanonicalNickname{ .len = @intCast(raw.len) };
    for (raw, 0..) |byte, index| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return error.InvalidNickname;
        result.display_bytes[index] = byte;
        result.canonical_bytes[index] = std.ascii.toLower(byte);
    }
    return result;
}
