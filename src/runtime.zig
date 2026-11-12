const std = @import("std");

pub const Mode = enum { serve, migrate_only };

pub fn parseArgs(args: []const []const u8) error{InvalidArguments}!Mode {
    if (args.len == 1) return .serve;
    if (args.len == 2 and std.mem.eql(u8, args[1], "--migrate-only")) return .migrate_only;
    return error.InvalidArguments;
}
