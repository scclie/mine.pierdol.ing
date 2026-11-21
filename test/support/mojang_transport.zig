const std = @import("std");
const mojang = @import("mojang");
const transport = @import("mojang_transport");
pub const selected = transport.Capability{ .age = 2, .curl = "8.23.0", .ares = "1.34.9", .tls = "OpenSSL/3.6.5", .ssl = true, .async_dns = true };
pub const Time = struct {
    now: u64 = 0,
    fn read(ctx: *anyopaque) u64 {
        const t: *Time = @ptrCast(@alignCast(ctx));
        return t.now;
    }
    pub fn clock(t: *Time) mojang.Clock {
        return .{ .context = t, .now_ns = read };
    }
};

// track only successful real setopt calls without sending requests
pub const Options = struct {
    calls: usize = 0,
    seen: [64]transport.c.CURLoption = undefined,
    pub fn fail(_: *Options, _: transport.Operation) bool {
        return false;
    }
    pub fn optionFailure(_: *Options) ?transport.c.CURLcode {
        return null;
    }
    pub fn after(_: *Options, _: transport.Operation) void {}
    pub fn checkedOption(self: *Options, option: transport.c.CURLoption, value: anytype) !void {
        const c = transport.c;
        for (self.seen[0..self.calls]) |previous| try std.testing.expect(previous != option);
        self.seen[self.calls] = option;
        self.calls += 1;
        if (comptime @TypeOf(value) == c_long) {
            const expected: c_long = switch (option) {
                c.CURLOPT_HTTPGET, c.CURLOPT_NOSIGNAL, c.CURLOPT_SSL_VERIFYPEER, c.CURLOPT_FORBID_REUSE, c.CURLOPT_FRESH_CONNECT => 1,
                c.CURLOPT_SSL_VERIFYHOST => 2,
                c.CURLOPT_FOLLOWLOCATION, c.CURLOPT_MAXREDIRS, c.CURLOPT_SSL_OPTIONS, c.CURLOPT_NOPROGRESS, c.CURLOPT_HTTP_CONTENT_DECODING => 0,
                c.CURLOPT_HTTP_VERSION => c.CURL_HTTP_VERSION_1_1,
                c.CURLOPT_SSLVERSION => c.CURL_SSLVERSION_TLSv1_2,
                c.CURLOPT_NETRC => c.CURL_NETRC_IGNORED,
                c.CURLOPT_TIMEOUT_MS, c.CURLOPT_CONNECTTIMEOUT_MS => 2000,
                c.CURLOPT_MAXFILESIZE_LARGE => 8192,
                else => return error.UnexpectedLongOption,
            };
            try std.testing.expectEqual(expected, value);
        } else if (comptime @TypeOf(value) == [*:0]const u8) {
            const expected: []const u8 = switch (option) {
                c.CURLOPT_URL => "https://api.minecraftservices.com/minecraft/profile/lookup/name/Paper_Sacculos",
                c.CURLOPT_PROTOCOLS_STR, c.CURLOPT_REDIR_PROTOCOLS_STR => "https",
                c.CURLOPT_PROXY, c.CURLOPT_CAPATH => "",
                c.CURLOPT_NOPROXY => "*",
                else => return error.UnexpectedStringOption,
            };
            try std.testing.expectEqualStrings(expected, std.mem.span(value));
        } else if (comptime @TypeOf(value) == *c.curl_blob) {
            try std.testing.expectEqual(@as(c.CURLoption, c.CURLOPT_CAINFO_BLOB), option);
            try std.testing.expectEqual(@as(c_uint, c.CURL_BLOB_COPY), value.flags);
            try std.testing.expect(value.len > 0 and value.len <= 1024 * 1024);
        } else if (comptime @TypeOf(value) == *c.curl_slist) {
            try std.testing.expectEqual(@as(c.CURLoption, c.CURLOPT_HTTPHEADER), option);
            try std.testing.expectEqualStrings("Accept: application/json", std.mem.span(value.data));
            try std.testing.expectEqualStrings("Accept-Encoding: identity", std.mem.span(value.next.*.data));
            try std.testing.expect(value.next.*.next == null);
        } else switch (option) {
            c.CURLOPT_WRITEDATA, c.CURLOPT_HEADERDATA, c.CURLOPT_XFERINFODATA, c.CURLOPT_WRITEFUNCTION, c.CURLOPT_HEADERFUNCTION, c.CURLOPT_XFERINFOFUNCTION => {},
            else => return error.UnexpectedPointerOption,
        }
    }
};
pub fn checkSetupFailures() !void {
    var client = try transport.Client.init(std.testing.allocator);
    defer client.deinit();
    // use the real vtable to compile the owner loop
    // reject forged input before admission or any socket/provider calls
    var invalid = try @import("domain").nickname.validateNickname("paper_sacculos");
    invalid.len = 255;
    var time = Time{};
    var cancel = mojang.Cancel{};
    const iface = client.transport();
    try std.testing.expectError(error.MinecraftProfileResponseInvalid, iface.attempt_fn(iface.context, invalid, time.clock(), 5_000_000_000, 2_000_000_000, &cancel));
    const nickname = try @import("domain").nickname.validateNickname("paper_sacculos");
    {
        var null_return = Faults{ .fail_at = 0 };
        var failed = transport.Owned(Faults){ .api = &null_return };
        defer failed.deinit();
        var failed_capture = transport.Capture.init(time.clock(), 5_000_000_000, 2_000_000_000, &cancel);
        try std.testing.expectError(error.OutOfMemory, failed.setup(client.ca, nickname, &failed_capture));
    }
    var reference = Faults{};
    var capture = transport.Capture.init(time.clock(), 5_000_000_000, 2_000_000_000, &cancel);
    var owned = transport.Owned(Faults){ .api = &reference };
    try owned.setup(client.ca, nickname, &capture);
    owned.deinit();
    const steps = reference.step;
    try std.testing.expect(steps > 30);
    try std.testing.expect(reference.easy == 0 and reference.multi == 0 and !reference.added and reference.lists == 0);
    for ([_]transport.c.CURLcode{ transport.c.CURLE_UNKNOWN_OPTION, transport.c.CURLE_OUT_OF_MEMORY }) |option_code| {
        for (0..steps) |fail_at| {
            var faults = Faults{ .fail_at = fail_at, .option_code = option_code };
            capture = transport.Capture.init(time.clock(), 5_000_000_000, 2_000_000_000, &cancel);
            var partial = transport.Owned(Faults){ .api = &faults };
            const outcome = partial.setup(client.ca, nickname, &capture);
            partial.deinit();
            // Idempotent guarded ladder; list nodes from both appends are one list.
            partial.deinit();
            const expected: anyerror = switch (faults.failed_operation.?) {
                .easy_init, .multi_init, .slist_append => error.OutOfMemory,
                .option => error.TransportSetupFailed,
                .add => error.TransportMultiFailed,
                else => unreachable,
            };
            try std.testing.expectError(expected, outcome);
            try std.testing.expect(faults.easy == 0 and faults.multi == 0 and !faults.added and faults.lists == 0);
        }
    }
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocateClient, .{});
}

fn allocateClient(allocator: std.mem.Allocator) !void {
    var client = try transport.Client.init(allocator);
    defer client.deinit();
}

const Faults = struct {
    fail_at: ?usize = null,
    step: usize = 0,
    easy: usize = 0,
    multi: usize = 0,
    lists: usize = 0,
    added: bool = false,
    failed_operation: ?transport.Operation = null,
    option_code: transport.c.CURLcode = transport.c.CURLE_UNKNOWN_OPTION,
    pub fn fail(self: *Faults, operation: transport.Operation) bool {
        const index = self.step;
        self.step += 1;
        if (self.fail_at == index) {
            self.failed_operation = operation;
            return true;
        }
        return false;
    }
    pub fn optionFailure(self: *Faults) ?transport.c.CURLcode {
        return if (self.fail(.option)) self.option_code else null;
    }
    pub fn after(self: *Faults, operation: transport.Operation) void {
        switch (operation) {
            .easy_init => self.easy += 1,
            .multi_init => self.multi += 1,
            .slist_append => self.lists += 1,
            .add => self.added = true,
            .remove => {
                std.debug.assert(self.added);
                self.added = false;
            },
            .easy_cleanup => {
                std.debug.assert(!self.added and self.easy == 1);
                self.easy -= 1;
            },
            .multi_cleanup => {
                std.debug.assert(self.easy == 0 and self.multi == 1);
                self.multi -= 1;
            },
            .slist_free => {
                std.debug.assert(self.easy == 0 and self.multi == 0 and self.lists > 0);
                self.lists = 0;
            },
            .option => {},
        }
    }
};
