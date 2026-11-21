const std = @import("std");
const domain = @import("domain");
pub const CanonicalNickname = domain.nickname.CanonicalNickname;
pub const Observation = domain.licensed_admission.Observation;

pub const Clock = struct {
    context: *anyopaque,
    now_ns: *const fn (*anyopaque) u64,
    /// test wait hook, bounded sleeps in prod
    sleep_ns: ?*const fn (*anyopaque, u64) void = null,
    pub fn now(self: Clock) u64 { return self.now_ns(self.context); }
    fn sleep(self: Clock, ns: u64) void {
        if (self.sleep_ns) |sleep_fn| sleep_fn(self.context, ns) else std.time.sleep(ns);
    }
};

/// keep at a fixed address while used by clock
pub const Monotonic = struct {
    origin: std.time.Instant,
    pub fn init() !Monotonic { return .{ .origin = try std.time.Instant.now() }; }
    fn read(ctx: *anyopaque) u64 {
        const self: *Monotonic = @ptrCast(@alignCast(ctx));
        const instant = std.time.Instant.now() catch return std.math.maxInt(u64);
        if (instant.order(self.origin) == .lt) return std.math.maxInt(u64);
        return instant.since(self.origin);
    }
    pub fn clock(self: *Monotonic) Clock { return .{ .context = self, .now_ns = read }; }
};

pub const Limits = struct {
    pub const total_ns: u64 = 5 * std.time.ns_per_s;
    pub const attempt_ns: u64 = 2 * std.time.ns_per_s;
    pub const reserve_ns: u64 = 250 * std.time.ns_per_ms;
};
pub const Cancel = struct { requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false) };
pub const Response = struct {
    status: u16,
    body: [8192]u8,
    body_len: usize,
    retry_after_ms: ?u64 = null,
};
pub const Transport = struct {
    context: *anyopaque,
    attempt_fn: *const fn (*anyopaque, CanonicalNickname, Clock, u64, u64, *const Cancel) anyerror!Response,
};
pub const Resolver = struct {
    context: *anyopaque,
    clock: Clock,
    resolve_fn: *const fn (*anyopaque, CanonicalNickname, u64) anyerror!Observation,
    pub fn resolve(self: Resolver, name: CanonicalNickname) !Observation {
        const start = self.clock.now();
        const deadline = std.math.add(u64, start, Limits.total_ns) catch return error.MinecraftProfileLookupUnavailable;
        validateName(name) catch return error.MinecraftProfileLookupInvalid;
        const found = self.resolve_fn(self.context, name, deadline) catch |err| {
            // The internal response-validation reason is not a fourth public
            // outcome: expose the approved lookup error-table name to services.
            if (err == error.MinecraftProfileResponseInvalid) return error.MinecraftProfileLookupInvalid;
            return err;
        };
        const now = self.clock.now();
        if (now < start or now >= deadline or found.observed_ns < start or found.observed_ns > now) return error.MinecraftProfileLookupUnavailable;
        validateName(found.requested) catch return error.MinecraftProfileLookupInvalid;
        validateName(found.returned) catch return error.MinecraftProfileLookupInvalid;
        if (!std.mem.eql(u8, name.display(), found.requested.display()) or
            !std.mem.eql(u8, name.canonical(), found.returned.canonical())) return error.MinecraftProfileLookupInvalid;
        return found;
    }
};

pub fn validateName(name: CanonicalNickname) !void {
    // Check len before slicing - CanonicalNickname is deliberately a plain value.
    if (name.len < 3 or name.len > 16) return error.MinecraftProfileResponseInvalid;
    const checked = domain.nickname.validateNickname(name.display()) catch return error.MinecraftProfileResponseInvalid;
    if (!std.mem.eql(u8, checked.canonical(), name.canonical())) return error.MinecraftProfileResponseInvalid;
}

pub fn parse(requested: CanonicalNickname, body: []const u8, now: u64) !Observation {
    try validateName(requested);
    if (body.len > 8192) return error.MinecraftProfileResponseInvalid;
    var depth: usize = 0;
    var quoted = false;
    var escaped = false;
    for (body) |byte| {
        if (quoted) {
            if (escaped) { escaped = false; } else if (byte == '\\') { escaped = true; } else if (byte == '"') { quoted = false; }
        } else switch (byte) {
            '"' => quoted = true,
            '{', '[' => { depth += 1; if (depth > 8) return error.MinecraftProfileResponseInvalid; },
            '}', ']' => { if (depth == 0) return error.MinecraftProfileResponseInvalid; depth -= 1; },
            else => {},
        }
    }
    if (depth != 0 or quoted) return error.MinecraftProfileResponseInvalid;
    var storage: [32768]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    auditKeys(fixed.allocator(), body) catch return error.MinecraftProfileResponseInvalid;
    fixed.reset();
    var parsed = std.json.parseFromSlice(std.json.Value, fixed.allocator(), body, .{ .duplicate_field_behavior = .@"error", .allocate = .alloc_always, .max_value_len = 8192 }) catch return error.MinecraftProfileResponseInvalid;
    defer parsed.deinit();
    if (parsed.value != .object) return error.MinecraftProfileResponseInvalid;
    const object = parsed.value.object;
    const id = object.get("id") orelse return error.MinecraftProfileResponseInvalid;
    const name = object.get("name") orelse return error.MinecraftProfileResponseInvalid;
    if (id != .string or name != .string) return error.MinecraftProfileResponseInvalid;
    for ([_][]const u8{ "demo", "legacy" }) |key| {
        if (object.get(key)) |value| {
            if (value != .bool) return error.MinecraftProfileResponseInvalid;
            if (std.mem.eql(u8, key, "demo") and value.bool) return error.MinecraftProfileResponseInvalid;
        }
    }
    const returned = domain.nickname.validateNickname(name.string) catch return error.MinecraftProfileResponseInvalid;
    if (!std.mem.eql(u8, requested.canonical(), returned.canonical())) return error.MinecraftProfileResponseInvalid;
    return .{ .requested = requested, .returned = returned, .uuid = domain.mojang_uuid.Uuid.parseProvider(id.string) catch return error.MinecraftProfileResponseInvalid, .observed_ns = now };
}

// zig 0.13 ignores duplicate_field_behavior for Value
// check decoded keys at every level before parsing
// reuse bounded storage, never compare raw key text
fn auditKeys(allocator: std.mem.Allocator, body: []const u8) !void {
    var scanner = std.json.Scanner.initCompleteInput(allocator, body);
    defer scanner.deinit();
    try auditValue(allocator, &scanner, try scanner.nextAllocMax(allocator, .alloc_always, 8192));
    if (try scanner.next() != .end_of_document) return error.InvalidJson;
}
fn auditValue(allocator: std.mem.Allocator, scanner: *std.json.Scanner, token: std.json.Token) anyerror!void {
    switch (token) {
        .object_begin => {
            var keys = std.StringHashMap(void).init(allocator);
            defer keys.deinit();
            while (true) {
                const next = try scanner.nextAllocMax(allocator, .alloc_always, 8192);
                if (next == .object_end) return;
                if (next != .allocated_string) return error.InvalidJson;
                const entry = try keys.getOrPut(next.allocated_string);
                if (entry.found_existing) return error.DuplicateField;
                try auditValue(allocator, scanner, try scanner.nextAllocMax(allocator, .alloc_always, 8192));
            }
        },
        .array_begin => while (true) {
            const next = try scanner.nextAllocMax(allocator, .alloc_always, 8192);
            if (next == .array_end) return;
            try auditValue(allocator, scanner, next);
        },
        .allocated_string, .allocated_number, .number, .string, .true, .false, .null => {},
        else => return error.InvalidJson,
    }
}

/// owns admission and lifecycle state, client must outlive it and its drain
pub const Production = struct {
    clock: Clock,
    transport: Transport,
    cancellation: Cancel = .{},
    mutex: std.Thread.Mutex = .{},
    slots: usize = 0,
    timestamps: [30]u64 = [_]u64{0} ** 30,
    count: usize = 0,
    cooldown: u64 = 0,
    last_now: u64 = 0,

    pub fn init(clock: Clock, transport: Transport) Production { return .{ .clock = clock, .transport = transport }; }
    pub fn resolver(self: *Production) Resolver { return .{ .context = self, .clock = self.clock, .resolve_fn = resolve }; }
    pub fn cancel(self: *Production) void { self.cancellation.requested.store(true, .release); }
    pub fn deinit(self: *Production) void {
        self.cancel();
        while (true) {
            self.mutex.lock();
            const drained = self.slots == 0;
            self.mutex.unlock();
            if (drained) return;
            std.time.sleep(std.time.ns_per_ms);
        }
    }
    fn available(self: *Production, now: u64) bool {
        if (self.cancellation.requested.load(.acquire) or now < self.last_now or now < self.cooldown) return false;
        self.last_now = now;
        return true;
    }
    // caller holds lock, compact ring in place without refunds
    fn token(self: *Production, now: u64) bool {
        var retained: usize = 0;
        for (self.timestamps[0..self.count]) |stamp| {
            if (now < stamp or now - stamp < 60 * std.time.ns_per_s) {
                self.timestamps[retained] = stamp;
                retained += 1;
            }
        }
        self.count = retained;
        if (retained == 30) return false;
        self.timestamps[retained] = now;
        self.count += 1;
        return true;
    }
    fn checkedNow(self: *Production, last: *u64, limit: u64) !u64 {
        const now = self.clock.now();
        if (self.cancellation.requested.load(.acquire) or now < last.* or now >= limit) return error.MinecraftProfileLookupUnavailable;
        last.* = now;
        return now;
    }
    fn resolve(ctx: *anyopaque, name: CanonicalNickname, deadline: u64) !Observation {
        const self: *Production = @ptrCast(@alignCast(ctx));
        const start = deadline - Limits.total_ns;
        var last = start;
        const cutoff = deadline - Limits.reserve_ns;
        var now = try self.checkedNow(&last, cutoff);
        if (!self.mutex.tryLock()) return error.MinecraftProfileLookupUnavailable;
        if (!self.available(now) or self.slots >= 2 or !self.token(now)) {
            self.mutex.unlock();
            return error.MinecraftProfileLookupUnavailable;
        }
        self.slots += 1;
        self.mutex.unlock();
        defer {
            self.mutex.lock();
            self.slots -= 1;
            self.mutex.unlock();
        }
        var attempt: usize = 0;
        while (attempt < 2) : (attempt += 1) {
            now = try self.checkedNow(&last, cutoff);
            if (cutoff - now < std.time.ns_per_ms) return error.MinecraftProfileLookupUnavailable;
            if (attempt != 0) {
                if (!self.mutex.tryLock()) return error.MinecraftProfileLookupUnavailable;
                const allowed = self.available(now) and self.token(now);
                self.mutex.unlock();
                if (!allowed) return error.MinecraftProfileLookupUnavailable;
            }
            const attempt_deadline = now + @min(Limits.attempt_ns, cutoff - now);
            var retry_ms: u64 = 100;
            const response_or_error = self.transport.attempt_fn(self.transport.context, name, self.clock, deadline, attempt_deadline, &self.cancellation);
            now = try self.checkedNow(&last, deadline);
            if (now >= attempt_deadline) return error.MinecraftProfileLookupUnavailable;
            if (response_or_error) |response| {
                switch (response.status) {
                    200 => {
                        if (response.body_len > response.body.len) return error.MinecraftProfileResponseInvalid;
                        const found = try parse(name, response.body[0..response.body_len], now);
                        _ = try self.checkedNow(&last, attempt_deadline);
                        return found;
                    },
                    204, 404 => return error.MinecraftProfileNotFound,
                    429 => {
                        const delay = @as(u64, @min(response.retry_after_ms orelse 1000, 60000)) * std.time.ns_per_ms;
                        self.mutex.lock();
                        self.cooldown = @max(self.cooldown, std.math.add(u64, now, delay) catch std.math.maxInt(u64));
                        self.mutex.unlock();
                        return error.MinecraftProfileLookupUnavailable;
                    },
                    500...599 => if (response.status == 503) { retry_ms = @max(retry_ms, response.retry_after_ms orelse 0); },
                    else => return error.MinecraftProfileResponseInvalid,
                }
            } else |err| {
                if (err == error.MinecraftProfileResponseInvalid) return error.MinecraftProfileResponseInvalid;
                if (err != error.ConnectionTransient) return error.MinecraftProfileLookupUnavailable;
            }
            if (attempt == 1) return error.MinecraftProfileLookupUnavailable;
            now = try self.checkedNow(&last, cutoff);
            const wait_ns = std.math.mul(u64, retry_ms, std.time.ns_per_ms) catch return error.MinecraftProfileLookupUnavailable;
            if (cutoff - now < std.time.ns_per_ms or wait_ns > cutoff - now - std.time.ns_per_ms) return error.MinecraftProfileLookupUnavailable;
            const wake = now + wait_ns;
            while (now < wake) {
                self.clock.sleep(@min(25 * std.time.ns_per_ms, wake - now));
                now = try self.checkedNow(&last, cutoff);
            }
        }
        return error.MinecraftProfileLookupUnavailable;
    }
};
