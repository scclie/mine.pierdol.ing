// build.zig runs only contract and game-auth boundary tests, not listener fixtures.
// ReleaseFast avoids debug allocator issues without changing production settings.
// std.testing checks remain enabled in all fixtures.
comptime {
    _ = @import("game_auth_contract_test.zig");
    _ = @import("game_auth_boundary_test.zig");
    _ = @import("game_auth_service").GameAuthService;
    _ = @import("game_auth_repository").Repository;
    _ = @import("game_auth_routes");
    _ = @import("config");
    _ = @import("http_server");
}
