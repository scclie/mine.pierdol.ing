const domain = @import("domain");
const mojang = @import("mojang");
pub const Fake = struct {
    calls: usize = 0,
    last_name: ?domain.nickname.CanonicalNickname = null,
    result: ?mojang.Observation = null,
    uuid: ?domain.mojang_uuid.Uuid = null,
    failure: ?anyerror = null,
    now_ns: u64 = 0,
    before_return: ?*const fn (*anyopaque) anyerror!void = null,
    hook_context: ?*anyopaque = null,
    fn now(ctx: *anyopaque) u64 {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        return self.now_ns;
    }
    fn resolve(ctx: *anyopaque, name: domain.nickname.CanonicalNickname, _: u64) !mojang.Observation {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.last_name = name;
        if (self.before_return) |hook| try hook(self.hook_context orelse return error.MissingHookContext);
        if (self.failure) |err| return err;
        if (self.result) |result| return result;
        if (self.uuid) |uuid| return .{ .requested = name, .returned = name, .uuid = uuid, .observed_ns = self.now_ns };
        return error.UnexpectedProviderCall;
    }
    pub fn resolver(self: *Fake) mojang.Resolver {
        return .{ .context = self, .clock = .{ .context = self, .now_ns = now }, .resolve_fn = resolve };
    }
};
