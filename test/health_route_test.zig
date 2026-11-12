const std = @import("std");
const http = @import("http_server");
const health = @import("health");

test "health route returns its fixed unauthenticated contract" {
    var server = http.Server.init(std.testing.allocator);
    defer server.deinit();
    try health.register(&server);

    var get = try server.dispatch(.{ .method = .GET, .target = "/api/v1/healthz" });
    defer get.deinit();
    try std.testing.expectEqual(@as(u16, 200), get.status);
    try std.testing.expectEqualStrings("{\"status\":\"ok\"}\n", get.body);
    try std.testing.expectEqualStrings("application/json; charset=utf-8", get.header("Content-Type").?);
    try std.testing.expectEqualStrings("no-store", get.header("Cache-Control").?);

    var post = try server.dispatch(.{ .method = .POST, .target = "/api/v1/healthz" });
    defer post.deinit();
    try std.testing.expectEqual(@as(u16, 405), post.status);
    try std.testing.expectEqualStrings("GET", post.header("Allow").?);
}
