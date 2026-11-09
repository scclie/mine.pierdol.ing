const std = @import("std");

pub fn main() !void {
    if (std.posix.getenv("DATABASE_URL") == null) {
        try std.io.getStdErr().writer().writeAll("mine-api: configure DATABASE_URL before starting\n");
        std.process.exit(1);
    }
}
