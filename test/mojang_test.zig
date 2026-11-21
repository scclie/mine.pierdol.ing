const std = @import("std");
const domain = @import("domain");
const mojang = @import("mojang");
const fake_mojang = @import("fake_mojang");
const testing = std.testing;
// observation contains the domain Uuid.format() value method, not std.fmt's formatting protocol
fn expectFailure(expected: anyerror, result: anyerror!mojang.Observation) !void {
    if (result) |_| return error.ExpectedFailure else |err| try testing.expectEqual(expected, err);
}
const good = "{\"id\":\"069a79f444e94726a5befca90e38aaf5\",\"name\":\"Paper_Sacculos\"}";

fn name() !domain.nickname.CanonicalNickname {
    return domain.nickname.validateNickname("paper_sacculos");
}

test "mojang lookup failure is typed and bounded" {
    var fake = fake_mojang.Fake{ .failure = error.MinecraftProfileLookupUnavailable };
    try expectFailure(error.MinecraftProfileLookupUnavailable, fake.resolver().resolve(try name()));
    try testing.expectEqual(@as(usize, 1), fake.calls);
    try testing.expectEqualStrings("paper_sacculos", fake.last_name.?.display());
}

test "mojang fake fails closed and invokes competing mutation before publication" {
    var fake = fake_mojang.Fake{};
    try expectFailure(error.UnexpectedProviderCall, fake.resolver().resolve(try name()));
    const Hook = struct {
        fn run(ctx: *anyopaque) !void {
            const f: *fake_mojang.Fake = @ptrCast(@alignCast(ctx));
            try testing.expectEqualStrings("paper_sacculos", f.last_name.?.display());
            return error.CompetingMutation;
        }
    };
    fake.before_return = Hook.run;
    fake.hook_context = &fake;
    try expectFailure(error.CompetingMutation, fake.resolver().resolve(try name()));
}

test "mojang bounded parser accepts strict IDs casing and bounded unknown metadata" {
    for ([_][]const u8{ good, "{\"id\":\"069a79f4-44e9-4726-a5be-fca90e38aaf5\",\"name\":\"PAPER_SACCULOS\",\"legacy\":false,\"demo\":false,\"extra\":{\"text\":\"{[\\\"}\"}}" }) |body| {
        const found = try mojang.parse(try name(), body, 17);
        try testing.expectEqualStrings("069a79f4-44e9-4726-a5be-fca90e38aaf5", &found.uuid.format());
        try testing.expectEqual(@as(u64, 17), found.observed_ns);
    }
}

test "mojang bounded parser rejects invalid ambiguous and mismatched profiles" {
    const invalid = [_][]const u8{
        "[]", "{}", "{", "{\"id\":2,\"name\":\"paper_sacculos\"}",
        "{\"id\":\"00000000000000000000000000000000\",\"name\":\"paper_sacculos\"}",
        "{\"id\":\"069a79f444e94726a5befca90e38aaf5\",\"name\":\"other\"}",
        "{\"id\":\"069a79f444e94726a5befca90e38aaf5\",\"name\":\"paper_sacculos\",\"demo\":true}",
        "{\"id\":\"069a79f444e94726a5befca90e38aaf5\",\"name\":\"paper_sacculos\",\"legacy\":null}",
        "{\"id\":\"069a79f444e94726a5befca90e38aaf5\",\"name\":\"paper_sacculos\",\"name\":\"paper_sacculos\"}",
        "{\"a\":[[[[[[[[[]]]]]]]]]}",
    };
    for (invalid) |body| try expectFailure(error.MinecraftProfileResponseInvalid, mojang.parse(try name(), body, 0));
    const oversized = [_]u8{' '} ** 8193;
    try expectFailure(error.MinecraftProfileResponseInvalid, mojang.parse(try name(), &oversized, 0));
}

test "mojang duplicate fields include escaped keys and unknown nested metadata" {
    for ([_][]const u8{
        "{\"id\":\"069a79f444e94726a5befca90e38aaf5\",\"name\":\"paper_sacculos\",\"na\\u006de\":\"paper_sacculos\"}",
        "{\"id\":\"069a79f444e94726a5befca90e38aaf5\",\"name\":\"paper_sacculos\",\"extra\":{\"x\":1,\"x\":2}}",
    }) |body| try expectFailure(error.MinecraftProfileResponseInvalid, mojang.parse(try name(), body, 0));
}

const Script = struct {
    now: u64 = 0,
    calls: usize = 0,
    statuses: []const u16 = &.{200},
    failure: ?anyerror = null,
    retry_ms: ?u64 = null,
    elapsed: u64 = 0,
    production: ?*mojang.Production = null,
    cancel_on_sleep: bool = false,
    sleep_calls: usize = 0,
    clock_step_after_call: u64 = 0,
    fn time(ctx: *anyopaque) u64 {
        const s: *Script = @ptrCast(@alignCast(ctx));
        const now = s.now;
        if (s.calls != 0) s.now += s.clock_step_after_call;
        return now;
    }
    fn sleep(ctx: *anyopaque, ns: u64) void {
        const s: *Script = @ptrCast(@alignCast(ctx));
        std.debug.assert(ns <= 25_000_000);
        s.sleep_calls += 1;
        s.now += ns;
        if (s.cancel_on_sleep) s.production.?.cancel();
    }
    fn clock(s: *Script) mojang.Clock { return .{ .context = s, .now_ns = time, .sleep_ns = sleep }; }
    fn attempt(ctx: *anyopaque, _: domain.nickname.CanonicalNickname, _: mojang.Clock, original: u64, deadline: u64, _: *const mojang.Cancel) !mojang.Response {
        const s: *Script = @ptrCast(@alignCast(ctx));
        try testing.expect(deadline <= original - 250_000_000);
        try testing.expect(deadline - s.now <= 2_000_000_000);
        const index = s.calls;
        s.calls += 1;
        s.now += s.elapsed;
        if (s.failure) |err| return err;
        var response = mojang.Response{ .status = s.statuses[@min(index, s.statuses.len - 1)], .body = undefined, .body_len = good.len, .retry_after_ms = s.retry_ms };
        @memcpy(response.body[0..good.len], good);
        return response;
    }
    fn transport(s: *Script) mojang.Transport { return .{ .context = s, .attempt_fn = attempt }; }
};

test "mojang status policy retries only transient or 5xx at most once" {
    for ([_]u16{204, 404, 400, 401, 403, 301, 429, 500, 503, 599}) |status| {
        var script = Script{ .statuses = &.{status} };
        var production = mojang.Production.init(script.clock(), script.transport());
        defer production.deinit();
        const result = production.resolver().resolve(try name());
        if (status == 204 or status == 404) try expectFailure(error.MinecraftProfileNotFound, result)
        else if (status == 400 or status == 401 or status == 403 or status == 301) try expectFailure(error.MinecraftProfileLookupInvalid, result)
        else try expectFailure(error.MinecraftProfileLookupUnavailable, result);
        try testing.expectEqual(@as(usize, if (status >= 500) 2 else 1), script.calls);
    }
    for ([_]anyerror{error.ConnectionTransient, error.DnsFailure, error.TlsFailure, error.DeadlineExceeded, error.MinecraftProfileResponseInvalid}) |err| {
        var script = Script{ .failure = err };
        var production = mojang.Production.init(script.clock(), script.transport());
        defer production.deinit();
        _ = production.resolver().resolve(try name()) catch {};
        try testing.expectEqual(@as(usize, if (err == error.ConnectionTransient) 2 else 1), script.calls);
    }
}

test "mojang retries share original budget and suppress late success" {
    var script = Script{ .statuses = &.{ 503, 200 }, .retry_ms = 6000 };
    var production = mojang.Production.init(script.clock(), script.transport());
    defer production.deinit();
    try expectFailure(error.MinecraftProfileLookupUnavailable, production.resolver().resolve(try name()));
    try testing.expectEqual(@as(usize, 1), script.calls);
    script.retry_ms = 200;
    const found = try production.resolver().resolve(try name());
    try testing.expectEqualStrings("paper_sacculos", found.requested.display());
    script.elapsed = 5_000_000_000;
    try expectFailure(error.MinecraftProfileLookupUnavailable, production.resolver().resolve(try name()));
}

test "mojang rolling attempt budget cooldown cancellation and try lock reject without calls" {
    var script = Script{};
    var production = mojang.Production.init(script.clock(), script.transport());
    defer production.deinit();
    for (0..30) |_| _ = try production.resolver().resolve(try name());
    try expectFailure(error.MinecraftProfileLookupUnavailable, production.resolver().resolve(try name()));
    try testing.expectEqual(@as(usize, 30), script.calls);
    script.now = 60_000_000_000;
    _ = try production.resolver().resolve(try name());
    production.mutex.lock();
    try expectFailure(error.MinecraftProfileLookupUnavailable, production.resolver().resolve(try name()));
    production.mutex.unlock();
    production.slots = 2;
    try expectFailure(error.MinecraftProfileLookupUnavailable, production.resolver().resolve(try name()));
    production.slots = 0;
    script.statuses = &.{429};
    script.retry_ms = 120_000;
    try expectFailure(error.MinecraftProfileLookupUnavailable, production.resolver().resolve(try name()));
    const count = script.calls;
    try expectFailure(error.MinecraftProfileLookupUnavailable, production.resolver().resolve(try name()));
    try testing.expectEqual(count, script.calls);
    script.now += 60_000_000_000;
    script.statuses = &.{200};
    _ = try production.resolver().resolve(try name());
    production.cancel();
    try expectFailure(error.MinecraftProfileLookupUnavailable, production.resolver().resolve(try name()));
}

test "mojang resolver rejects forged names stale observations and clock regression" {
    var fake = fake_mojang.Fake{ .result = try mojang.parse(try name(), good, 1), .now_ns = 2 };
    try expectFailure(error.MinecraftProfileLookupUnavailable, fake.resolver().resolve(try name()));
    var forged = try name();
    forged.len = 255;
    try expectFailure(error.MinecraftProfileLookupInvalid, fake.resolver().resolve(forged));
}

test "mojang backoff cancels within one slice and failed retries consume rate budget" {
    var script = Script{ .statuses = &.{503}, .cancel_on_sleep = true };
    var production = mojang.Production.init(script.clock(), script.transport());
    script.production = &production;
    try expectFailure(error.MinecraftProfileLookupUnavailable, production.resolver().resolve(try name()));
    try testing.expectEqual(@as(usize, 1), script.sleep_calls);
    try testing.expectEqual(@as(usize, 1), script.calls);
    production.deinit();

    script = Script{ .failure = error.ConnectionTransient };
    production = mojang.Production.init(script.clock(), script.transport());
    defer production.deinit();
    for (0..15) |_| try expectFailure(error.MinecraftProfileLookupUnavailable, production.resolver().resolve(try name()));
    try expectFailure(error.MinecraftProfileLookupUnavailable, production.resolver().resolve(try name()));
    try testing.expectEqual(@as(usize, 30), script.calls);
}

test "mojang 503 longer valid wait replaces backoff" {
    var script = Script{ .statuses = &.{503, 200}, .retry_ms = 200 };
    var production = mojang.Production.init(script.clock(), script.transport());
    defer production.deinit();
    _ = try production.resolver().resolve(try name());
    try testing.expectEqual(@as(u64, 200_000_000), script.now);
    try testing.expectEqual(@as(usize, 2), script.calls);
}

test "mojang resolver rejects observations returned after original deadline or clock regression" {
    const Jump = struct {
        fn late(ctx: *anyopaque) !void { const f: *fake_mojang.Fake = @ptrCast(@alignCast(ctx)); f.now_ns = 5_000_000_000; }
        fn backwards(ctx: *anyopaque) !void { const f: *fake_mojang.Fake = @ptrCast(@alignCast(ctx)); f.now_ns = 0; }
    };
    var fake = fake_mojang.Fake{ .result = try mojang.parse(try name(), good, 0), .before_return = Jump.late };
    fake.hook_context = &fake;
    try expectFailure(error.MinecraftProfileLookupUnavailable, fake.resolver().resolve(try name()));
    fake.now_ns = 10;
    fake.before_return = Jump.backwards;
    try expectFailure(error.MinecraftProfileLookupUnavailable, fake.resolver().resolve(try name()));
}

test "mojang rejects publication when parsing crosses attempt deadline" {
    var script = Script{ .elapsed = 1_999_999_999, .clock_step_after_call = 1 };
    var production = mojang.Production.init(script.clock(), script.transport());
    defer production.deinit();
    try expectFailure(error.MinecraftProfileLookupUnavailable, production.resolver().resolve(try name()));
    try testing.expectEqual(@as(usize, 1), script.calls);
}

test "mojang startup monotonic clock exposes checked relative nanoseconds" {
    var monotonic = try mojang.Monotonic.init();
    const clock = monotonic.clock();
    const before = clock.now();
    try testing.expect(before != std.math.maxInt(u64));
    const after = clock.now();
    try testing.expect(after >= before and after != std.math.maxInt(u64));
}
