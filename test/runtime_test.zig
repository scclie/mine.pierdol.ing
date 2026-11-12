const std = @import("std");
const runtime = @import("runtime");

test "runtime accepts only serve and migrate-only modes" {
    try std.testing.expectEqual(runtime.Mode.serve, try runtime.parseArgs(&.{"mine-api"}));
    try std.testing.expectEqual(runtime.Mode.migrate_only, try runtime.parseArgs(&.{ "mine-api", "--migrate-only" }));
}

test "runtime rejects extra positional and unknown arguments" {
    try std.testing.expectError(error.InvalidArguments, runtime.parseArgs(&.{ "mine-api", "--migrate-only", "extra" }));
    try std.testing.expectError(error.InvalidArguments, runtime.parseArgs(&.{ "mine-api", "--unknown" }));
    try std.testing.expectError(error.InvalidArguments, runtime.parseArgs(&.{ "mine-api", "serve" }));
}
