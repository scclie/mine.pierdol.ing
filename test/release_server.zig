const std = @import("std");
const fake_mojang = @import("fake_mojang");
const db = @import("db_pool");
const config = @import("config");
const http = @import("http_server");
const discord = @import("discord");
const routes = @import("auth_routes");
const health = @import("health");
const migrations = @import("migrations");

test "release_server" {
    const allocator = std.heap.page_allocator;
    var configuration = try config.Config.load(allocator);
    defer configuration.deinit();
    var pool = try db.Pool.open(allocator, configuration.database_url);
    defer pool.close();
    try migrations.apply(&pool);
    const origin = std.posix.getenv("TASK12_OAUTH_ORIGIN") orelse return error.MissingLocalProvider;
    if (!std.mem.startsWith(u8, origin, "http://127.0.0.1:")) return error.NonLocalProvider;
    const token = try std.fmt.allocPrint(allocator, "{s}/token", .{origin});
    const identity = try std.fmt.allocPrint(allocator, "{s}/me", .{origin});
    const authorize = try std.fmt.allocPrint(allocator, "{s}/authorize", .{origin});
    var service = discord.DiscordService.initProductionForTest(allocator, &pool, &configuration, token, identity);
    service.endpoint.authorization_endpoint = authorize;
    var fake: fake_mojang.Fake = .{};
    const resolver = fake.resolver();
    var router = try routes.Router.init(allocator, &service, &configuration, &resolver);
    defer router.deinit();
    var server = http.Server.init(allocator);
    defer server.deinit();
    try health.register(&server);
    try routes.register(&server, &router);
    try server.serve(configuration.http_listen_address);
}
