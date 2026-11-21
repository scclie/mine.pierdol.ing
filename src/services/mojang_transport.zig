const std = @import("std");
const domain = @import("domain");
const mojang = @import("mojang");
const build = @import("mojang_build");
pub const c = @cImport({
    @cInclude("curl/curl.h");
    @cInclude("errno.h");
    @cInclude("openssl/pem.h");
    @cInclude("openssl/err.h");
    @cInclude("openssl/ssl.h");
});

comptime {
    if (build.ca_bundle.len == 0 or build.curl_version.len == 0 or build.ares_version.len == 0 or build.openssl_version.len == 0)
        @compileError("Mojang transport requires all four explicit selected MOJANG_* build metadata values");
}

pub const Capability = struct {
    age: u32,
    curl: []const u8,
    ares: ?[]const u8,
    tls: []const u8,
    ssl: bool,
    async_dns: bool,
};
pub fn admit(info: Capability) !void {
    if (info.age < c.CURLVERSION_SECOND or !info.ssl or !info.async_dns or
        !std.mem.eql(u8, info.curl, build.curl_version) or
        !std.mem.eql(u8, info.ares orelse return error.TransportDependencyRejected, build.ares_version) or
        !std.mem.eql(u8, info.tls, "OpenSSL/" ++ build.openssl_version)) return error.TransportDependencyRejected;
}

/// startup only, use the compiled store path instead of runtime ca discovery
pub fn validateCa(bytes: []const u8) !void {
    if (bytes.len == 0 or bytes.len > 1024 * 1024) return error.InvalidCaBundle;
    const bio = c.BIO_new_mem_buf(bytes.ptr, @intCast(bytes.len)) orelse return error.OutOfMemory;
    defer _ = c.BIO_free(bio);
    var count: usize = 0;
    while (c.PEM_read_bio_X509(bio, null, null, null)) |cert| {
        count += 1;
        c.X509_free(cert);
    }
    c.ERR_clear_error();
    if (count == 0) return error.InvalidCaBundle;
}

pub fn loadCa(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = std.fs.openFileAbsolute(path, .{}) catch return error.InvalidCaBundle;
    defer file.close();
    const ca = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidCaBundle;
    errdefer allocator.free(ca);
    try validateCa(ca);
    return ca;
}

/// convert http date on receipt, use wall time only for this hint
pub fn retryAfter(text: []const u8, wall_seconds: i64) ?u64 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 128) return null;
    var digits = true;
    for (trimmed) |byte| {
        if (!std.ascii.isDigit(byte)) digits = false;
    }
    if (digits) {
        const seconds = std.fmt.parseInt(u64, trimmed, 10) catch return null;
        return @as(u64, @min(seconds, 60)) * 1000;
    }
    // curl_getdate accepts more formats, enforce strict IMF-fixdate
    if (trimmed.len != 29 or trimmed[3] != ',' or !std.mem.endsWith(u8, trimmed, " GMT")) return null;
    var storage: [129]u8 = undefined;
    @memcpy(storage[0..trimmed.len], trimmed);
    storage[trimmed.len] = 0;
    const date = c.curl_getdate(@ptrCast(&storage), null);
    if (date < 0) return null;
    const delay = std.math.sub(i64, date, wall_seconds) catch return null;
    return @as(u64, @intCast(std.math.clamp(delay, 0, 60))) * 1000;
}

pub const Capture = struct {
    clock: mojang.Clock,
    original: u64,
    deadline: u64,
    cancel: *const mojang.Cancel,
    last: u64,
    headers: usize = 0,
    response: mojang.Response = .{ .status = 0, .body = undefined, .body_len = 0 },
    failure: ?anyerror = null,
    pub fn init(clock: mojang.Clock, original: u64, deadline: u64, cancel: *const mojang.Cancel) Capture {
        return .{ .clock = clock, .original = original, .deadline = deadline, .cancel = cancel, .last = clock.now() };
    }
    fn check(self: *Capture) !u64 {
        if (self.failure) |err| return err;
        const now = self.clock.now();
        if (self.cancel.requested.load(.acquire)) return error.Cancelled;
        if (now < self.last or now >= self.original or now >= self.deadline) return error.DeadlineExceeded;
        self.last = now;
        return now;
    }
    fn byteCount(self: *Capture, size: usize, nmemb: usize) !usize {
        _ = try self.check();
        return std.math.mul(usize, size, nmemb) catch error.MinecraftProfileResponseInvalid;
    }
    fn body(self: *Capture, ptr: [*c]u8, size: usize, nmemb: usize) !usize {
        const len = try self.byteCount(size, nmemb);
        if (len > self.response.body.len - self.response.body_len or (len != 0 and ptr == null)) return error.MinecraftProfileResponseInvalid;
        if (len != 0) @memcpy(self.response.body[self.response.body_len..][0..len], ptr[0..len]);
        self.response.body_len += len;
        return len;
    }
    fn header(self: *Capture, ptr: [*c]u8, size: usize, nmemb: usize) !usize {
        const len = try self.byteCount(size, nmemb);
        if (len > 16384 - self.headers or (len != 0 and ptr == null)) return error.MinecraftProfileResponseInvalid;
        self.headers += len;
        if (len == 0) return 0;
        const line = ptr[0..len];
        if (std.mem.startsWith(u8, line, "HTTP/")) {
            self.response.retry_after_ms = null;
        } else if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            const key = line[0..colon];
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t\r\n");
            if (std.ascii.eqlIgnoreCase(key, "Content-Encoding")) {
                if (!std.ascii.eqlIgnoreCase(value, "identity")) return error.MinecraftProfileResponseInvalid;
            } else if (std.ascii.eqlIgnoreCase(key, "Retry-After")) {
                if (self.response.retry_after_ms != null) return error.MinecraftProfileResponseInvalid;
                self.response.retry_after_ms = retryAfter(value, std.time.timestamp());
            }
        }
        return len;
    }
};
pub fn bodyCallback(ptr: [*c]u8, size: usize, nmemb: usize, ctx: ?*anyopaque) callconv(.C) usize {
    const self: *Capture = @ptrCast(@alignCast(ctx orelse return 0));
    return self.body(ptr, size, nmemb) catch |err| {
        self.failure = err;
        return 0;
    };
}
pub fn headerCallback(ptr: [*c]u8, size: usize, nmemb: usize, ctx: ?*anyopaque) callconv(.C) usize {
    const self: *Capture = @ptrCast(@alignCast(ctx orelse return 0));
    return self.header(ptr, size, nmemb) catch |err| {
        self.failure = err;
        return 0;
    };
}
fn progressCallback(ctx: ?*anyopaque, _: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t) callconv(.C) c_int {
    const self: *Capture = @ptrCast(@alignCast(ctx orelse return 1));
    _ = self.check() catch |err| {
        self.failure = err;
        return 1;
    };
    return 0;
}

fn easyCheck(result: c.CURLcode) !void {
    if (result != c.CURLE_OK) return error.TransportSetupFailed;
}
fn multiCheck(result: c.CURLMcode) !void {
    if (result != c.CURLM_OK) return error.TransportMultiFailed;
}
fn observed(api: anytype, option: c.CURLoption, value: anytype) !void {
    if (@hasDecl(@TypeOf(api.*), "checkedOption")) try api.checkedOption(option, value);
}
fn setLong(api: anytype, easy: *c.CURL, option: c.CURLoption, value: c_long) !void {
    try easyCheck(api.optionFailure() orelse c.curl_easy_setopt(easy, option, value));
    try observed(api, option, value);
}
fn setOff(api: anytype, easy: *c.CURL, option: c.CURLoption, value: c.curl_off_t) !void {
    try easyCheck(api.optionFailure() orelse c.curl_easy_setopt(easy, option, value));
    try observed(api, option, value);
}
fn setString(api: anytype, easy: *c.CURL, option: c.CURLoption, value: [*:0]const u8) !void {
    try easyCheck(api.optionFailure() orelse c.curl_easy_setopt(easy, option, value));
    try observed(api, option, value);
}
fn setData(api: anytype, easy: *c.CURL, option: c.CURLoption, value: *anyopaque) !void {
    try easyCheck(api.optionFailure() orelse c.curl_easy_setopt(easy, option, value));
    try observed(api, option, value);
}
fn setBlob(api: anytype, easy: *c.CURL, value: *c.curl_blob) !void {
    try easyCheck(api.optionFailure() orelse c.curl_easy_setopt(easy, c.CURLOPT_CAINFO_BLOB, value));
    try observed(api, c.CURLOPT_CAINFO_BLOB, value);
}
fn setList(api: anytype, easy: *c.CURL, value: *c.curl_slist) !void {
    try easyCheck(api.optionFailure() orelse c.curl_easy_setopt(easy, c.CURLOPT_HTTPHEADER, value));
    try observed(api, c.CURLOPT_HTTPHEADER, value);
}
const WriteFn = *const fn ([*c]u8, usize, usize, ?*anyopaque) callconv(.C) usize;
const ProgressFn = *const fn (?*anyopaque, c.curl_off_t, c.curl_off_t, c.curl_off_t, c.curl_off_t) callconv(.C) c_int;
fn setWrite(api: anytype, easy: *c.CURL, option: c.CURLoption, value: WriteFn) !void {
    try easyCheck(api.optionFailure() orelse c.curl_easy_setopt(easy, option, value));
    try observed(api, option, value);
}
fn setProgress(api: anytype, easy: *c.CURL, value: ProgressFn) !void {
    try easyCheck(api.optionFailure() orelse c.curl_easy_setopt(easy, c.CURLOPT_XFERINFOFUNCTION, value));
    try observed(api, c.CURLOPT_XFERINFOFUNCTION, value);
}

pub const Operation = enum { easy_init, multi_init, slist_append, option, add, remove, easy_cleanup, multi_cleanup, slist_free };
pub const Direct = struct {
    pub fn fail(_: *Direct, _: Operation) bool {
        return false;
    }
    pub fn optionFailure(_: *Direct) ?c.CURLcode {
        return null;
    }
    pub fn after(_: *Direct, _: Operation) void {}
};

/// isolated easy+multi per attempt with injectable api operations for failure tests
pub fn Owned(comptime Api: type) type {
    return struct {
        api: *Api,
        easy: ?*c.CURL = null,
        multi: ?*c.CURLM = null,
        list: ?*c.curl_slist = null,
        added: bool = false,
        const Self = @This();
        pub fn setup(self: *Self, ca: []const u8, name: domain.nickname.CanonicalNickname, capture: *Capture) !void {
            try mojang.validateName(name);
            const now = try capture.check();
            const remaining = @min(@as(u64, 2000), (capture.deadline - now) / std.time.ns_per_ms);
            if (remaining == 0) return error.DeadlineExceeded;
            const easy_result = if (self.api.fail(.easy_init)) null else c.curl_easy_init();
            self.easy = easy_result orelse return error.OutOfMemory;
            self.api.after(.easy_init);
            const multi_result = if (self.api.fail(.multi_init)) null else c.curl_multi_init();
            self.multi = multi_result orelse return error.OutOfMemory;
            self.api.after(.multi_init);
            inline for (.{ "Accept: application/json", "Accept-Encoding: identity" }) |line| {
                const list_result = if (self.api.fail(.slist_append)) null else c.curl_slist_append(self.list, line);
                self.list = list_result orelse return error.OutOfMemory;
                self.api.after(.slist_append);
            }
            const easy = self.easy.?;
            var url: [128]u8 = undefined;
            const endpoint = try std.fmt.bufPrintZ(&url, "https://api.minecraftservices.com/minecraft/profile/lookup/name/{s}", .{name.display()});
            try setString(self.api, easy, c.CURLOPT_URL, endpoint);
            inline for (.{ .{ c.CURLOPT_PROTOCOLS_STR, "https" }, .{ c.CURLOPT_REDIR_PROTOCOLS_STR, "https" }, .{ c.CURLOPT_PROXY, "" }, .{ c.CURLOPT_NOPROXY, "*" }, .{ c.CURLOPT_CAPATH, "" } }) |option| {
                try setString(self.api, easy, option[0], option[1]);
            }
            inline for (.{
                .{ c.CURLOPT_HTTPGET, @as(c_long, 1) },                            .{ c.CURLOPT_NOSIGNAL, @as(c_long, 1) },
                .{ c.CURLOPT_FOLLOWLOCATION, @as(c_long, 0) },                     .{ c.CURLOPT_MAXREDIRS, @as(c_long, 0) },
                .{ c.CURLOPT_HTTP_VERSION, @as(c_long, c.CURL_HTTP_VERSION_1_1) }, .{ c.CURLOPT_SSLVERSION, @as(c_long, c.CURL_SSLVERSION_TLSv1_2) },
                .{ c.CURLOPT_SSL_VERIFYPEER, @as(c_long, 1) },                     .{ c.CURLOPT_SSL_VERIFYHOST, @as(c_long, 2) },
                .{ c.CURLOPT_SSL_OPTIONS, @as(c_long, 0) },                        .{ c.CURLOPT_NETRC, @as(c_long, c.CURL_NETRC_IGNORED) },
                .{ c.CURLOPT_FORBID_REUSE, @as(c_long, 1) },                       .{ c.CURLOPT_FRESH_CONNECT, @as(c_long, 1) },
                .{ c.CURLOPT_NOPROGRESS, @as(c_long, 0) },                         .{ c.CURLOPT_HTTP_CONTENT_DECODING, @as(c_long, 0) },
            }) |option| {
                try setLong(self.api, easy, option[0], option[1]);
            }
            try setLong(self.api, easy, c.CURLOPT_TIMEOUT_MS, @intCast(remaining));
            try setLong(self.api, easy, c.CURLOPT_CONNECTTIMEOUT_MS, @intCast(remaining));
            try setOff(self.api, easy, c.CURLOPT_MAXFILESIZE_LARGE, @as(c.curl_off_t, 8192));
            var blob = c.curl_blob{ .data = @ptrCast(@constCast(ca.ptr)), .len = ca.len, .flags = c.CURL_BLOB_COPY };
            try setBlob(self.api, easy, &blob);
            try setList(self.api, easy, self.list.?);
            inline for (.{ c.CURLOPT_WRITEDATA, c.CURLOPT_HEADERDATA, c.CURLOPT_XFERINFODATA }) |option| {
                try setData(self.api, easy, option, capture);
            }
            try setWrite(self.api, easy, c.CURLOPT_WRITEFUNCTION, bodyCallback);
            try setWrite(self.api, easy, c.CURLOPT_HEADERFUNCTION, headerCallback);
            try setProgress(self.api, easy, progressCallback);
            _ = try capture.check();
            const add_result = if (self.api.fail(.add)) c.CURLM_BAD_EASY_HANDLE else c.curl_multi_add_handle(self.multi.?, easy);
            try multiCheck(add_result);
            self.added = true;
            self.api.after(.add);
        }
        pub fn deinit(self: *Self) void {
            if (self.added) {
                // no return/reuse is safe after an unproven removal/destruction.
                if (c.curl_multi_remove_handle(self.multi.?, self.easy.?) != c.CURLM_OK) @panic("fatal transport integrity: remove");
                self.added = false;
                self.api.after(.remove);
            }
            if (self.easy) |easy| {
                c.curl_easy_cleanup(easy);
                self.easy = null;
                self.api.after(.easy_cleanup);
            }
            if (self.multi) |multi| {
                if (c.curl_multi_cleanup(multi) != c.CURLM_OK) @panic("fatal transport integrity: cleanup");
                self.multi = null;
                self.api.after(.multi_cleanup);
            }
            if (self.list) |list| {
                c.curl_slist_free_all(list);
                self.list = null;
                self.api.after(.slist_free);
            }
        }
        fn drive(self: *Self, capture: *Capture) !mojang.Response {
            while (true) {
                _ = try capture.check();
                var running: c_int = 0;
                try multiCheck(c.curl_multi_perform(self.multi.?, &running));
                _ = try capture.check();
                var queued: c_int = 0;
                while (c.curl_multi_info_read(self.multi.?, &queued)) |message| {
                    _ = try capture.check();
                    if (message.*.msg != c.CURLMSG_DONE or message.*.easy_handle != self.easy.?) return error.TransportMultiFailed;
                    if (capture.failure) |err| return err;
                    const result = message.*.data.result;
                    if (result != c.CURLE_OK) {
                        var os_errno: c_long = 0;
                        try easyCheck(c.curl_easy_getinfo(self.easy.?, c.CURLINFO_OS_ERRNO, &os_errno));
                        return classify(result, os_errno);
                    }
                    var status: c_long = 0;
                    try easyCheck(c.curl_easy_getinfo(self.easy.?, c.CURLINFO_RESPONSE_CODE, &status));
                    if (status < 100 or status > 599) return error.MinecraftProfileResponseInvalid;
                    capture.response.status = @intCast(status);
                    _ = try capture.check();
                    return capture.response;
                }
                if (running == 0) return error.TransportMultiFailed;
                const now = try capture.check();
                const wait = @min(@as(u64, 25), (capture.deadline - now) / std.time.ns_per_ms);
                if (wait == 0) return error.DeadlineExceeded;
                var fds: c_int = 0;
                try multiCheck(c.curl_multi_poll(self.multi.?, null, 0, @intCast(wait), &fds));
                _ = try capture.check();
            }
        }
    };
}
pub fn classify(code: c.CURLcode, os_errno: c_long) anyerror {
    return switch (code) {
        c.CURLE_COULDNT_CONNECT => switch (os_errno) {
            c.ECONNREFUSED, c.ENETUNREACH, c.EHOSTUNREACH, c.ECONNRESET => error.ConnectionTransient,
            else => error.MinecraftProfileLookupUnavailable,
        },
        c.CURLE_RECV_ERROR, c.CURLE_SEND_ERROR => if (os_errno == c.ECONNRESET) error.ConnectionTransient else error.MinecraftProfileLookupUnavailable,
        c.CURLE_COULDNT_RESOLVE_HOST, c.CURLE_COULDNT_RESOLVE_PROXY => error.DnsFailure,
        c.CURLE_OPERATION_TIMEDOUT => error.DeadlineExceeded,
        c.CURLE_SSL_CONNECT_ERROR, c.CURLE_PEER_FAILED_VERIFICATION, c.CURLE_SSL_CACERT_BADFILE => error.TlsFailure,
        else => error.MinecraftProfileResponseInvalid,
    };
}

var global_mutex: std.Thread.Mutex = .{};
var global_clients: usize = 0;
fn acquireGlobal() !void {
    global_mutex.lock();
    defer global_mutex.unlock();
    if (global_clients == 0) {
        // disable ambient openssl config before curl initialization
        // trust only the compiled ca bundle
        if (c.OPENSSL_init_ssl(c.OPENSSL_INIT_NO_LOAD_CONFIG, null) != 1) return error.TransportDependencyRejected;
        // keep process-wide EPIPE handling to prevent termination on broken pipes
        const action = std.posix.Sigaction{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.empty_sigset, .flags = 0 };
        try std.posix.sigaction(std.posix.SIG.PIPE, &action, null);
        if (c.curl_global_init(@as(c_long, c.CURL_GLOBAL_DEFAULT)) != c.CURLE_OK) return error.TransportDependencyRejected;
    }
    global_clients += 1;
}
fn releaseGlobal() void {
    global_mutex.lock();
    defer global_mutex.unlock();
    global_clients -= 1;
    if (global_clients == 0) c.curl_global_cleanup();
}

pub const Client = struct {
    allocator: std.mem.Allocator,
    ca: []u8,
    mutex: std.Thread.Mutex = .{},
    closing: bool = false,
    active: usize = 0,
    pub fn init(allocator: std.mem.Allocator) !Client {
        try acquireGlobal();
        errdefer releaseGlobal();
        const info = c.curl_version_info(c.CURLVERSION_NOW) orelse return error.TransportDependencyRejected;
        // check age before reading ares, introduced in SECOND
        if (info.*.age < c.CURLVERSION_SECOND) return error.TransportDependencyRejected;
        try admit(.{ .age = @intCast(info.*.age), .curl = if (info.*.version) |value| std.mem.span(value) else "", .ares = if (info.*.ares) |value| std.mem.span(value) else null, .tls = if (info.*.ssl_version) |value| std.mem.span(value) else "", .ssl = info.*.features & c.CURL_VERSION_SSL != 0, .async_dns = info.*.features & c.CURL_VERSION_ASYNCHDNS != 0 });
        const ca = try loadCa(allocator, build.ca_bundle);
        return .{ .allocator = allocator, .ca = ca };
    }
    pub fn transport(self: *Client) mojang.Transport {
        return .{ .context = self, .attempt_fn = attempt };
    }
    pub fn deinit(self: *Client) void {
        self.mutex.lock();
        self.closing = true;
        while (self.active != 0) {
            self.mutex.unlock();
            std.time.sleep(std.time.ns_per_ms);
            self.mutex.lock();
        }
        self.mutex.unlock();
        self.allocator.free(self.ca);
        releaseGlobal();
    }
    fn attempt(ctx: *anyopaque, name: domain.nickname.CanonicalNickname, clock: mojang.Clock, original: u64, deadline: u64, cancel: *const mojang.Cancel) !mojang.Response {
        const self: *Client = @ptrCast(@alignCast(ctx));
        try mojang.validateName(name);
        if (!self.mutex.tryLock()) return error.MinecraftProfileLookupUnavailable;
        if (self.closing) {
            self.mutex.unlock();
            return error.Cancelled;
        }
        self.active += 1;
        self.mutex.unlock();
        defer {
            self.mutex.lock();
            self.active -= 1;
            self.mutex.unlock();
        }
        if (original < mojang.Limits.reserve_ns or deadline > original - mojang.Limits.reserve_ns) return error.DeadlineExceeded;
        var capture = Capture.init(clock, original, deadline, cancel);
        var direct = Direct{};
        var owned = Owned(Direct){ .api = &direct };
        const response = blk: {
            defer owned.deinit();
            try owned.setup(self.ca, name, &capture);
            break :blk try owned.drive(&capture);
        };
        // all curl resources are gone before publish
        _ = try capture.check();
        return response;
    }
};
