const http = @import("http_server");
const response = http.response;

pub fn register(server: *http.Server) !void {
    try server.route(.GET, "/api/v1/healthz", server, handle);
}

fn handle(context: *anyopaque, _: http.Request, _: []const u8) !response.Response {
    const server: *http.Server = @ptrCast(@alignCast(context));
    var result = try response.Response.init(server.allocator, 200, "{\"status\":\"ok\"}\n");
    errdefer result.deinit();
    try result.addHeader("Content-Type", "application/json; charset=utf-8");
    try result.addHeader("Cache-Control", "no-store");
    return result;
}
