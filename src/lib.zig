const std = @import("std");

pub const types = @import("domain/types.zig");
pub const nickname = @import("domain/nickname.zig");
pub const application = @import("domain/application.zig");
pub const audit = @import("domain/audit.zig");
pub const password = @import("domain/password.zig");
pub const mojang_uuid = @import("domain/mojang_uuid.zig");
pub const licensed_admission = @import("domain/licensed_admission.zig");

test "library builds" {
    try std.testing.expect(true);
}
