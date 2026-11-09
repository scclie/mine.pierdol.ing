const std = @import("std");
const c = @cImport({
    @cInclude("libpq-fe.h");
});

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

        const parameter_values = try self.allocator.alloc(?[*:0]const u8, parameters.len);
        defer {
            for (parameter_values, parameters) |parameter_value, parameter| {
                if (parameter != null) self.allocator.free(std.mem.span(parameter_value.?));
            }
            self.allocator.free(parameter_values);
        }

        for (parameters, 0..) |parameter, index| {
            parameter_values[index] = if (parameter) |value| (try self.allocator.dupeZ(u8, value)).ptr else null;
        }

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
