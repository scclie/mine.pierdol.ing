const std = @import("std");
const game_auth = @import("game_auth_routes");
const http = @import("http_server");

pub const Mode = enum { serve, migrate_only };

pub fn parseArgs(args: []const []const u8) error{InvalidArguments}!Mode {
    if (args.len == 1) return .serve;
    if (args.len == 2 and std.mem.eql(u8, args[1], "--migrate-only")) return .migrate_only;
    return error.InvalidArguments;
}

pub fn registerGameAuth(server: *http.Server, router: *game_auth.Router) !void {
    try game_auth.register(server, router);
}
