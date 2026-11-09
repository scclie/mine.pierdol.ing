const std = @import("std");
const db = @import("db_pool");
const domain = @import("domain");
const migrations = @import("db/migrations.zig");
const config = @import("config");
const http = @import("http_server");
const discord = @import("discord");
const auth_routes = @import("auth_routes");

pub fn main() !void {
    var configuration = try config.Config.load(std.heap.page_allocator);
    defer configuration.deinit();

    var deny_list = try domain.password.loadDefaultDenyList(std.heap.page_allocator);
    defer deny_list.deinit();

    var pool = try db.Pool.open(std.heap.page_allocator, configuration.database_url);
    defer pool.close();
    try migrations.apply(&pool);

    var discord_service = discord.DiscordService.initProduction(std.heap.page_allocator, &pool, &configuration);
    var auth_router = try auth_routes.Router.init(std.heap.page_allocator, &discord_service, &configuration);
    defer auth_router.deinit();
    var server = http.Server.init(std.heap.page_allocator);
    defer server.deinit();
    try auth_routes.register(&server, &auth_router);
    try server.serve(configuration.http_listen_address);
}
