const std = @import("std");
const password_deny_list = @import("password_deny_list");

const minimum_password_length = 12;
const argon2 = std.crypto.pwhash.argon2;
const argon2_parameters = argon2.Params{ .t = 2, .m = 19 * 1024, .p = 1 };

pub const DenyList = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator, contents: []const u8) !DenyList {
        var entries = std.StringHashMap(void).init(allocator);
        errdefer {
            var iterator = entries.keyIterator();
            while (iterator.next()) |entry| allocator.free(entry.*);
            entries.deinit();
        }

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line_with_optional_cr| {
            const line = std.mem.trimRight(u8, line_with_optional_cr, "\r");
            if (line.len == 0) continue;

            const entry = try allocator.dupe(u8, line);
            _ = std.ascii.lowerString(entry, entry);
            if (entries.contains(entry)) {
                allocator.free(entry);
            } else {
                entries.put(entry, {}) catch |err| {
                    allocator.free(entry);
                    return err;
                };
            }
        }

        return .{ .allocator = allocator, .entries = entries };
    }

    pub fn deinit(self: *DenyList) void {
        var iterator = self.entries.keyIterator();
        while (iterator.next()) |entry| self.allocator.free(entry.*);
        self.entries.deinit();
    }

    fn contains(self: DenyList, candidate: []const u8) bool {
        return self.entries.contains(candidate);
    }
};

pub fn loadDefaultDenyList(allocator: std.mem.Allocator) !DenyList {
    return DenyList.init(allocator, password_deny_list.contents);
}

pub fn validatePassword(password: []const u8, deny_list: DenyList) !void {
    if (password.len < minimum_password_length) return error.PasswordTooShort;

    const normalized = try deny_list.allocator.dupe(u8, password);
    defer {
        std.crypto.utils.secureZero(u8, normalized);
        deny_list.allocator.free(normalized);
    }
    _ = std.ascii.lowerString(normalized, normalized);
    if (deny_list.contains(normalized)) return error.PasswordDenied;
}

pub fn hashPassword(allocator: std.mem.Allocator, password: []const u8) ![]u8 {
    const secret = try allocator.dupe(u8, password);
    defer {
        std.crypto.utils.secureZero(u8, secret);
        allocator.free(secret);
    }

    var encoded: [128]u8 = undefined;
    const hash = try argon2.strHash(secret, .{
        .allocator = allocator,
        .params = argon2_parameters,
        .mode = .argon2id,
    }, &encoded);
    return allocator.dupe(u8, hash);
}

pub fn verifyPassword(hash: []const u8, password: []const u8) !bool {
    const secret = try std.heap.page_allocator.dupe(u8, password);
    defer {
        std.crypto.utils.secureZero(u8, secret);
        std.heap.page_allocator.free(secret);
    }

    argon2.strVerify(hash, secret, .{ .allocator = std.heap.page_allocator }) catch |err| switch (err) {
        error.PasswordVerificationFailed => return false,
        else => return err,
    };
    return true;
}
