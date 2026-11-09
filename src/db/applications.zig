const std = @import("std");
const db = @import("db_pool");
const domain = @import("domain");

const nickname = domain.nickname;
const types = domain.types;

pub const Application = struct {
    user_id: i64,
    nickname: nickname.CanonicalNickname,
    client_type: types.ClientType,
    status: types.ApplicationStatus = .pending,
};

pub const CreateInput = struct {
    discord_id: []const u8,
    discord_username: []const u8,
    discord_global_name: ?[]const u8 = null,
    discord_avatar_hash: ?[]const u8 = null,
    nickname: nickname.CanonicalNickname,
    client_type: types.ClientType,
    about_me: []const u8,
    discovery_source: []const u8,
    password_hash: ?[]const u8,
};

pub const ApplicationRepository = struct {
    pool: *db.Pool,

    pub fn init(pool: *db.Pool) ApplicationRepository {
        return .{ .pool = pool };
    }

    pub fn create(self: *ApplicationRepository, input: CreateInput) !Application {
        switch (input.client_type) {
            .cracked => if (input.password_hash == null) return error.PasswordRequired,
            .licensed => if (input.password_hash != null) return error.PasswordNotAllowed,
        }

        var transaction = try self.pool.begin();
        errdefer transaction.rollback() catch {};

        var user_result = try transaction.query(
            "INSERT INTO users (discord_id, discord_username, discord_global_name, discord_avatar_hash) VALUES ($1, $2, $3, $4) RETURNING id",
            &.{ input.discord_id, input.discord_username, input.discord_global_name, input.discord_avatar_hash },
        );
        defer user_result.deinit();
        const user_id = try std.fmt.parseInt(i64, user_result.value(0, 0), 10);

        var user_id_buffer: [20]u8 = undefined;
        const user_id_parameter = try std.fmt.bufPrint(&user_id_buffer, "{d}", .{user_id});
        var application_result = try transaction.query(
            "INSERT INTO applications (user_id, minecraft_nickname, minecraft_nickname_normalized, client_type, about_me, discovery_source) VALUES ($1, $2, $3, $4::minecraft_client_type, $5, $6)",
            &.{ user_id_parameter, input.nickname.display(), input.nickname.canonical(), @tagName(input.client_type), input.about_me, input.discovery_source },
        );
        application_result.deinit();

        if (input.password_hash) |password_hash| {
            var credential_result = try transaction.query(
                "INSERT INTO password_credentials (user_id, password_hash) VALUES ($1, $2)",
                &.{ user_id_parameter, password_hash },
            );
            credential_result.deinit();
        }

        var audit_result = try transaction.query(
            "INSERT INTO audit_log (actor_user_id, subject_user_id, action, old_value, new_value, reason) VALUES (NULL, $1, 'application_created', NULL, NULL, NULL)",
            &.{user_id_parameter},
        );
        audit_result.deinit();

        try transaction.commit();
        return .{
            .user_id = user_id,
            .nickname = input.nickname,
            .client_type = input.client_type,
        };
    }

    pub fn replacePassword(self: *ApplicationRepository, user_id: i64, new_hash: []const u8) !void {
        var user_id_buffer: [20]u8 = undefined;
        const user_id_parameter = try std.fmt.bufPrint(&user_id_buffer, "{d}", .{user_id});
        var transaction = try self.pool.begin();
        errdefer transaction.rollback() catch {};

        var credential_result = try transaction.query(
            "WITH eligible_application AS (SELECT user_id FROM applications WHERE user_id = $1 AND client_type = 'cracked' AND status = 'approved' FOR UPDATE), updated_credential AS (UPDATE password_credentials SET password_hash = $2, changed_at = now() FROM eligible_application WHERE password_credentials.user_id = eligible_application.user_id RETURNING password_credentials.user_id) SELECT EXISTS(SELECT 1 FROM updated_credential)",
            &.{ user_id_parameter, new_hash },
        );
        const credential_updated = std.mem.eql(u8, credential_result.value(0, 0), "t");
        credential_result.deinit();
        if (!credential_updated) return error.PasswordChangeNotAllowed;

        var audit_result = try transaction.query(
            "INSERT INTO audit_log (actor_user_id, subject_user_id, action, old_value, new_value, reason) VALUES (NULL, $1, 'password_changed', NULL, NULL, NULL)",
            &.{user_id_parameter},
        );
        audit_result.deinit();

        try transaction.commit();
    }
};
