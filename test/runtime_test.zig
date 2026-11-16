const std = @import("std");
const runtime = @import("runtime");

test "runtime accepts only serve and migrate-only modes" {
    try std.testing.expectEqual(runtime.Mode.serve, try runtime.parseArgs(&.{"mine-api"}));
    try std.testing.expectEqual(runtime.Mode.migrate_only, try runtime.parseArgs(&.{ "mine-api", "--migrate-only" }));
}

test "runtime leaves game-auth paths unhandled when no game-auth router is registered" {
    var server = @import("http_server").Server.init(std.testing.allocator);
    defer server.deinit();
    var result = try server.dispatch(.{ .method = .GET, .target = "/internal/game-auth/v1/whitelist", .authorization = "Bearer not-a-game-auth-token" });
    defer result.deinit();
    try std.testing.expectEqual(@as(u16, 404), result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "\"outcome\":\"deny\"") == null);
}
