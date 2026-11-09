const std = @import("std");
const c = @cImport({
    @cInclude("libpq-fe.h");
});

test "pool parameter copy cleans up only initialized entries after allocation failure" {
    const Context = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const values = try copyParameterValues(allocator, &.{ "first", "second" });
            defer freeParameterValues(allocator, values);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Context.run, .{});
}

fn copyParameterValues(allocator: std.mem.Allocator, parameters: []const ?[]const u8) ![]?[*:0]const u8 {
    const parameter_values = try allocator.alloc(?[*:0]const u8, parameters.len);
    var initialized: usize = 0;
    errdefer {
        for (parameter_values[0..initialized]) |parameter_value| {
            if (parameter_value) |value| allocator.free(std.mem.span(value));
        }
        allocator.free(parameter_values);
    }

    for (parameters, 0..) |parameter, index| {
        parameter_values[index] = if (parameter) |value| (try allocator.dupeZ(u8, value)).ptr else null;
        initialized += 1;
    }
    return parameter_values;
}

fn freeParameterValues(allocator: std.mem.Allocator, parameter_values: []?[*:0]const u8) void {
    for (parameter_values) |parameter_value| {
        if (parameter_value) |value| allocator.free(std.mem.span(value));
    }
    allocator.free(parameter_values);
}

pub const Pool = struct {
    allocator: std.mem.Allocator,
    connection: *c.PGconn,

    pub fn open(allocator: std.mem.Allocator, database_url: []const u8) !Pool {
        const database_url_z = try allocator.dupeZ(u8, database_url);
        defer allocator.free(database_url_z);

        const connection = c.PQconnectdb(database_url_z.ptr) orelse return error.ConnectionFailed;
        errdefer c.PQfinish(connection);
        if (c.PQstatus(connection) != c.CONNECTION_OK) return error.ConnectionFailed;

        return .{
            .allocator = allocator,
            .connection = connection,
        };
    }

    pub fn close(self: *Pool) void {
        c.PQfinish(self.connection);
    }

    pub fn begin(self: *Pool) !Transaction {
        var result = try self.query("BEGIN", &.{});
        result.deinit();
        return .{ .pool = self };
    }

    pub fn query(self: *Pool, sql: []const u8, parameters: []const ?[]const u8) !Result {
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        const parameter_values = try copyParameterValues(self.allocator, parameters);
        defer freeParameterValues(self.allocator, parameter_values);

        const result = (if (parameters.len == 0)
            c.PQexec(self.connection, sql_z.ptr)
        else
            c.PQexecParams(
                self.connection,
                sql_z.ptr,
                @intCast(parameters.len),
                null,
                parameter_values.ptr,
                null,
                null,
                0,
            )) orelse return error.QueryFailed;
        errdefer c.PQclear(result);

        const status = c.PQresultStatus(result);
        if (status != c.PGRES_COMMAND_OK and status != c.PGRES_TUPLES_OK) return error.QueryFailed;

        return .{ .result = result };
    }
};

pub const Transaction = struct {
    pool: *Pool,

    pub fn query(self: *Transaction, sql: []const u8, parameters: []const ?[]const u8) !Result {
        return self.pool.query(sql, parameters);
    }

    pub fn commit(self: *Transaction) !void {
        var result = try self.pool.query("COMMIT", &.{});
        result.deinit();
    }

    pub fn rollback(self: *Transaction) !void {
        var result = try self.pool.query("ROLLBACK", &.{});
        result.deinit();
    }
};

pub const Result = struct {
    result: *c.PGresult,

    pub fn deinit(self: *Result) void {
        c.PQclear(self.result);
    }

    pub fn value(self: *const Result, row: usize, column: usize) []const u8 {
        const length: usize = @intCast(c.PQgetlength(self.result, @intCast(row), @intCast(column)));
        return c.PQgetvalue(self.result, @intCast(row), @intCast(column))[0..length];
    }
};
