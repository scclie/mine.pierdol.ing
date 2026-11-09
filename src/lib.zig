const std = @import("std");

pub const types = @import("domain/types.zig");
pub const nickname = @import("domain/nickname.zig");
pub const application = @import("domain/application.zig");
pub const audit = @import("domain/audit.zig");
pub const password = @import("domain/password.zig");

test "library builds" {
    try std.testing.expect(true);
}
