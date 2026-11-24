const std = @import("std");
const db = @import("db_pool");
const domain = @import("domain");
const migrations = @import("db/migrations.zig");
const config = @import("config");
const http = @import("http_server");
const discord = @import("discord");
const auth_routes = @import("auth_routes");
const health = @import("health");
const public_servers = @import("public_servers");
const public_ranking = @import("public_ranking");
const game_auth_routes = @import("game_auth_routes");
const active_minutes = @import("active_minutes");
const runtime = @import("runtime");
const mojang = @import("mojang");
const mojang_transport = @import("mojang_transport");

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

    var client = try mojang_transport.Client.init(std.heap.page_allocator);
    defer client.deinit();
    var monotonic = try mojang.Monotonic.init();
    var production = mojang.Production.init(monotonic.clock(), client.transport());
    defer production.deinit();
    const resolver = production.resolver();

    var deny_list = try domain.password.loadDefaultDenyList(std.heap.page_allocator);
    defer deny_list.deinit();

    var discord_service = discord.DiscordService.initProduction(std.heap.page_allocator, &pool, &configuration);
    var auth_router = try auth_routes.Router.init(std.heap.page_allocator, &discord_service, &configuration, &resolver);
    defer auth_router.deinit();
    var ranking_provider = try public_ranking.Provider.init(std.heap.page_allocator, &pool);
    defer ranking_provider.deinit();
    var server = http.Server.init(std.heap.page_allocator);
    defer server.deinit();
    try health.register(&server);
    var public_provider = public_servers.Provider.init(std.heap.page_allocator, &pool, &configuration);
    try public_servers.register(&server, &public_provider);
    try public_ranking.register(&server, &ranking_provider);
    try auth_routes.register(&server, &auth_router);
    if (configuration.game_auth_credentials.len > 0) {
        var game_auth_router = game_auth_routes.Router.init(std.heap.page_allocator, &pool, &configuration);
        defer game_auth_router.deinit();
        try runtime.registerGameAuth(&server, &game_auth_router);
        var active_minutes_router = active_minutes.Router.init(std.heap.page_allocator, &pool);
        try active_minutes.register(&server, &active_minutes_router);
        try server.serve(configuration.http_listen_address);
    } else try server.serve(configuration.http_listen_address);
}
