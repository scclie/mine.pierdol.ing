const std = @import("std");
const transport = @import("mojang_transport");
const support = @import("mojang_transport_support");
const domain = @import("domain");
const mojang = @import("mojang");
const build = @import("mojang_build");
const loader = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("link.h");
});

fn loadedObject(info: [*c]loader.struct_dl_phdr_info, _: usize, _: ?*anyopaque) callconv(.C) c_int {
    const path = std.mem.span(info.*.dlpi_name);
    if (path.len != 0 and !std.mem.startsWith(u8, path, "linux-vdso")) std.debug.print("MOJANG_LOADED {s}\n", .{path});
    return 0;
}

test "mojang transport dependency real Client metadata and loaded objects" {
    var client = try transport.Client.init(std.testing.allocator);
    defer client.deinit();
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(client.ca, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const metadata = try std.json.stringifyAlloc(std.testing.allocator, .{
        .ca_bundle = build.ca_bundle, .curl_version = build.curl_version,
        .ares_version = build.ares_version, .openssl_version = build.openssl_version,
        .ca_sha256 = &hex,
    }, .{});
    defer std.testing.allocator.free(metadata);
    std.debug.print("\nMOJANG_METADATA {s}\n", .{metadata});
    const executable = try std.fs.selfExePathAlloc(std.testing.allocator);
    defer std.testing.allocator.free(executable);
    std.debug.print("MOJANG_LOADED {s}\n", .{executable});
    try std.testing.expect(loader.dl_iterate_phdr(loadedObject, null) == 0);
}

test "mojang transport dependency admitted" {
    try transport.admit(support.selected);
    var wrong = support.selected;
    wrong.curl = "wrong";
    try std.testing.expectError(error.TransportDependencyRejected, transport.admit(wrong));
    wrong = support.selected;
    wrong.ares = "1.0";
    try std.testing.expectError(error.TransportDependencyRejected, transport.admit(wrong));
    wrong = support.selected;
    wrong.ssl = false;
    try std.testing.expectError(error.TransportDependencyRejected, transport.admit(wrong));
    wrong = support.selected;
    wrong.tls = "GnuTLS/3.5.9";
    try std.testing.expectError(error.TransportDependencyRejected, transport.admit(wrong));
    wrong = support.selected;
    wrong.age = 0;
    try std.testing.expectError(error.TransportDependencyRejected, transport.admit(wrong));
}

test "mojang transport dependency rejects threaded resolver" {
    var wrong = support.selected;
    wrong.ares = null;
    try std.testing.expectError(error.TransportDependencyRejected, transport.admit(wrong));
    wrong.ares = "";
    try std.testing.expectError(error.TransportDependencyRejected, transport.admit(wrong));
    wrong = support.selected;
    wrong.async_dns = false;
    try std.testing.expectError(error.TransportDependencyRejected, transport.admit(wrong));
}

test "mojang transport dependency rejects missing CA" {
    try std.testing.expectError(error.InvalidCaBundle, transport.loadCa(std.testing.allocator, "/tmp/opencode/licensed-uuid-lifecycle-sdd/task-3b-evidence/absent-ca-file"));
    try std.testing.expectError(error.InvalidCaBundle, transport.loadCa(std.testing.allocator, "/dev/null"));
    try std.testing.expectError(error.InvalidCaBundle, transport.validateCa(""));
    try std.testing.expectError(error.InvalidCaBundle, transport.validateCa("garbage"));
    const large = [_]u8{'x'} ** (1024 * 1024 + 1);
    try std.testing.expectError(error.InvalidCaBundle, transport.validateCa(&large));
    try std.testing.expectError(error.InvalidCaBundle, transport.validateCa("-----BEGIN CERTIFICATE-----\nbad\n-----END CERTIFICATE-----"));
}

test "mojang transport callback overflow caps encoding and deadlines" {
    var clock = support.Time{};
    var cancel = mojang.Cancel{};
    var capture = transport.Capture.init(clock.clock(), 5_000_000_000, 2_000_000_000, &cancel);
    try std.testing.expectEqual(@as(usize, 0), transport.bodyCallback(null, std.math.maxInt(usize), 2, &capture));
    try std.testing.expectEqual(error.MinecraftProfileResponseInvalid, capture.failure.?);
    capture = transport.Capture.init(clock.clock(), 5_000_000_000, 2_000_000_000, &cancel);
    var bytes = [_]u8{'x'} ** 8192;
    try std.testing.expectEqual(@as(usize, 8192), transport.bodyCallback(&bytes, 1, bytes.len, &capture));
    try std.testing.expectEqual(@as(usize, 0), transport.bodyCallback(&bytes, 1, 1, &capture));
    capture = transport.Capture.init(clock.clock(), 5_000_000_000, 2_000_000_000, &cancel);
    const encoding = "Content-Encoding: gzip\r\n";
    try std.testing.expectEqual(@as(usize, 0), transport.headerCallback(@constCast(encoding.ptr), 1, encoding.len, &capture));
    capture = transport.Capture.init(clock.clock(), 5_000_000_000, 2_000_000_000, &cancel);
    for (0..2) |_| _ = transport.headerCallback(&bytes, 1, bytes.len, &capture);
    try std.testing.expectEqual(@as(usize, 0), transport.headerCallback(&bytes, 1, 1, &capture));
    capture = transport.Capture.init(clock.clock(), 5_000_000_000, 2_000_000_000, &cancel);
    clock.now = 2_000_000_000;
    try std.testing.expectEqual(@as(usize, 0), transport.bodyCallback(&bytes, 1, 1, &capture));
    clock.now = 0;
    capture = transport.Capture.init(clock.clock(), 5_000_000_000, 2_000_000_000, &cancel);
    cancel.requested.store(true, .release);
    try std.testing.expectEqual(@as(usize, 0), transport.headerCallback(&bytes, 1, 1, &capture));
    try std.testing.expectEqual(error.Cancelled, capture.failure.?);
}

test "mojang transport dependency setup failures destroy partial ownership without network" {
    // the injected API fails setup, so no perform/poll/provider I/O is permitted.
    try support.checkSetupFailures();
}

test "mojang transport retry after parsing is bounded" {
    try std.testing.expectEqual(@as(?u64, 3000), transport.retryAfter("3", 0));
    try std.testing.expectEqual(@as(?u64, null), transport.retryAfter("-1", 0));
    try std.testing.expectEqual(@as(?u64, null), transport.retryAfter("999999999999999999999999", 0));
    try std.testing.expectEqual(@as(?u64, 60000), transport.retryAfter("9999", 0));
    try std.testing.expectEqual(@as(?u64, 3000), transport.retryAfter("Sun, 06 Nov 1994 08:49:37 GMT", 784111774));
    try std.testing.expectEqual(@as(?u64, 0), transport.retryAfter("Sun, 06 Nov 1994 08:49:37 GMT", 784111778));
    try std.testing.expectEqual(@as(?u64, 60000), transport.retryAfter("Sun, 06 Nov 1994 08:49:37 GMT", 0));
    try std.testing.expectEqual(@as(?u64, null), transport.retryAfter("Sun, 99 Nov 1994 08:49:37 GMT", 0));
}

test "mojang transport boundary revalidates manually forged nickname" {
    var forged = try domain.nickname.validateNickname("paper_sacculos");
    forged.display_bytes[0] = '/';
    try std.testing.expectError(error.MinecraftProfileResponseInvalid, mojang.validateName(forged));
    forged.len = 200;
    try std.testing.expectError(error.MinecraftProfileResponseInvalid, mojang.validateName(forged));
}

test "mojang transport retries only OS classified reset refusal or unreachable" {
    const c = transport.c;
    try std.testing.expectEqual(error.ConnectionTransient, transport.classify(c.CURLE_RECV_ERROR, c.ECONNRESET));
    try std.testing.expectEqual(error.ConnectionTransient, transport.classify(c.CURLE_COULDNT_CONNECT, c.ECONNREFUSED));
    try std.testing.expectEqual(error.ConnectionTransient, transport.classify(c.CURLE_COULDNT_CONNECT, c.ENETUNREACH));
    try std.testing.expectEqual(error.MinecraftProfileLookupUnavailable, transport.classify(c.CURLE_RECV_ERROR, 0));
    try std.testing.expectEqual(error.MinecraftProfileLookupUnavailable, transport.classify(c.CURLE_COULDNT_CONNECT, c.EACCES));
    try std.testing.expectEqual(error.TlsFailure, transport.classify(c.CURLE_SSL_CONNECT_ERROR, c.ECONNRESET));
}

test "mojang transport dependency startup establishes SIGPIPE ignore in disposable test process" {
    var client = try transport.Client.init(std.testing.allocator);
    defer client.deinit();
    // this entire isolated test artifact is disposable, never the running server.
    try std.posix.raise(std.posix.SIG.PIPE);
}

test "mojang transport dependency fixed destination survives poisoned environment" {
    var client = try transport.Client.init(std.testing.allocator);
    defer client.deinit();
    var time = support.Time{};
    var cancel = mojang.Cancel{};
    for (0..2) |_| {
        var options = support.Options{};
        var owned = transport.Owned(support.Options){ .api = &options };
        defer owned.deinit();
        var capture = transport.Capture.init(time.clock(), 5_000_000_000, 2_000_000_000, &cancel);
        try owned.setup(client.ca, try domain.nickname.validateNickname("Paper_Sacculos"), &capture);
        var url: [*c]u8 = null;
        try std.testing.expect(transport.c.curl_easy_getinfo(owned.easy.?, transport.c.CURLINFO_EFFECTIVE_URL, &url) == transport.c.CURLE_OK);
        try std.testing.expectEqualStrings("https://api.minecraftservices.com/minecraft/profile/lookup/name/Paper_Sacculos", std.mem.span(url));
        // Missing observer calls cannot satisfy proxy/CA option acceptance.
        try std.testing.expectEqual(@as(usize, 31), options.calls);
    }
}
