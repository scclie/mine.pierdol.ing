const std = @import("std");

pub const Uuid = struct {
    bytes: [16]u8,

    pub fn parseAdmin(text: []const u8) error{InvalidLicensedMojangUuid}!Uuid {
        const trimmed = std.mem.trim(u8, text, " \t\r\n\x0b\x0c");
        if (trimmed.len != 36) return error.InvalidLicensedMojangUuid;
        return parseProvider(trimmed);
    }

    pub fn parseProvider(text: []const u8) error{InvalidLicensedMojangUuid}!Uuid {
        if (text.len != 32 and text.len != 36) return error.InvalidLicensedMojangUuid;
        var result: Uuid = undefined;
        var offset: usize = 0;
        var nonzero = false;
        for (&result.bytes, 0..) |*byte, index| {
            if (text.len == 36 and (index == 4 or index == 6 or index == 8 or index == 10)) {
                if (text[offset] != '-') return error.InvalidLicensedMojangUuid;
                offset += 1;
            }
            const high = std.fmt.charToDigit(text[offset], 16) catch return error.InvalidLicensedMojangUuid;
            const low = std.fmt.charToDigit(text[offset + 1], 16) catch return error.InvalidLicensedMojangUuid;
            byte.* = high * 16 + low;
            nonzero = nonzero or byte.* != 0;
            offset += 2;
        }
        if (!nonzero) return error.InvalidLicensedMojangUuid;
        return result;
    }

    pub fn format(self: Uuid) [36]u8 {
        const hex = "0123456789abcdef";
        var result: [36]u8 = undefined;
        var offset: usize = 0;
        for (self.bytes, 0..) |byte, index| {
            if (index == 4 or index == 6 or index == 8 or index == 10) {
                result[offset] = '-';
                offset += 1;
            }
            result[offset] = hex[byte >> 4];
            result[offset + 1] = hex[byte & 15];
            offset += 2;
        }
        return result;
    }

    pub fn eql(self: Uuid, other: Uuid) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }
};
