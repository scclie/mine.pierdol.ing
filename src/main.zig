const std = @import("std");
const db = @import("db_pool");
const domain = @import("domain");
const migrations = @import("db/migrations.zig");
const config = @import("config");
const http = @import("http_server");
const discord = @import("discord");
const auth_routes = @import("auth_routes");
const health = @import("health");
const runtime = @import("runtime");

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);
    const mode = runtime.parseArgs(args) catch |err| {
        std.io.getStdErr().writer().writeAll("usage: mine-api [--migrate-only]\n") catch {};
        return err;
    };

    var configuration = try config.Config.load(std.heap.page_allocator);
    defer configuration.deinit();

    var pool = try db.Pool.open(std.heap.page_allocator, configuration.database_url);
    defer pool.close();
    try migrations.apply(&pool);

    if (mode == .migrate_only) return;

    var deny_list = try domain.password.loadDefaultDenyList(std.heap.page_allocator);
    defer deny_list.deinit();

    var discord_service = discord.DiscordService.initProduction(std.heap.page_allocator, &pool, &configuration);
    var auth_router = try auth_routes.Router.init(std.heap.page_allocator, &discord_service, &configuration);
    defer auth_router.deinit();
    var server = http.Server.init(std.heap.page_allocator);
    defer server.deinit();
    try health.register(&server);
    try auth_routes.register(&server, &auth_router);
    try server.serve(configuration.http_listen_address);
}
