-- serialize auth through the owning user lock.
-- issue/refresh lock the user first, then read fresh committed state.
-- mutations lock users by id, then generation and lease.
-- triggers cannot enforce lock order; unsafe direct dml fails on contention.
-- leases never store passwords or hashes.
ALTER TABLE applications DROP CONSTRAINT applications_user_id_fkey;
ALTER TABLE applications ADD CONSTRAINT applications_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

CREATE TABLE game_identities (
  identity_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id BIGINT NOT NULL UNIQUE REFERENCES applications(user_id) ON DELETE CASCADE,
  authentication_generation BIGINT NOT NULL DEFAULT 1 CHECK (authentication_generation > 0),
  licensed_mojang_uuid UUID CONSTRAINT game_identities_licensed_mojang_uuid_key UNIQUE NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE game_auth_whitelist_state (
  singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
  version BIGINT NOT NULL DEFAULT 0 CHECK (version >= 0)
);
INSERT INTO game_auth_whitelist_state (singleton, version) VALUES (TRUE, 0);

CREATE TABLE game_auth_leases (
  lease_hash BYTEA PRIMARY KEY CHECK (octet_length(lease_hash) = 32),
  identity_id BIGINT NOT NULL REFERENCES game_identities(identity_id) ON DELETE CASCADE,
  server_id TEXT NOT NULL,
  client_type minecraft_client_type NOT NULL,
  authentication_generation BIGINT NOT NULL CHECK (authentication_generation > 0),
  uuid TEXT NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX game_auth_leases_identity_idx ON game_auth_leases(identity_id);
CREATE INDEX game_auth_leases_expiry_idx ON game_auth_leases(expires_at, lease_hash);

CREATE TABLE game_auth_audit (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  server_id TEXT NOT NULL,
  user_id BIGINT REFERENCES users(id) ON DELETE SET NULL,
  outcome TEXT NOT NULL CHECK (outcome IN ('allow', 'deny', 'continue', 'disconnect')),
  reason_category TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX game_auth_audit_retention_idx ON game_auth_audit(created_at, id);

CREATE FUNCTION game_auth_next_whitelist_version() RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE next_version BIGINT;
BEGIN
  UPDATE game_auth_whitelist_state SET version = version + 1
  WHERE singleton = TRUE RETURNING version INTO next_version;
  RETURN next_version;
END;
$$;

CREATE FUNCTION game_auth_identity_mutation() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM id FROM users WHERE id=OLD.user_id FOR UPDATE NOWAIT;
    RETURN OLD;
  END IF;
  PERFORM id FROM users WHERE id=NEW.user_id FOR UPDATE NOWAIT;
  IF TG_OP = 'UPDATE' THEN
    IF NEW.identity_id IS DISTINCT FROM OLD.identity_id OR NEW.user_id IS DISTINCT FROM OLD.user_id THEN
      RAISE EXCEPTION 'immutable game identity';
    END IF;
    IF NEW.authentication_generation < OLD.authentication_generation THEN
      RAISE EXCEPTION 'authentication generation cannot decrease';
    END IF;
    IF NEW.licensed_mojang_uuid IS DISTINCT FROM OLD.licensed_mojang_uuid THEN
      NEW.authentication_generation := OLD.authentication_generation + 1;
    END IF;
    NEW.updated_at := now();
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER game_auth_identity_mutation BEFORE INSERT OR UPDATE OR DELETE ON game_identities
FOR EACH ROW EXECUTE FUNCTION game_auth_identity_mutation();

CREATE FUNCTION game_auth_identity_cursor() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' OR TG_OP = 'DELETE' THEN
    PERFORM game_auth_next_whitelist_version();
  ELSIF NEW.licensed_mojang_uuid IS DISTINCT FROM OLD.licensed_mojang_uuid THEN
    PERFORM game_auth_next_whitelist_version();
  END IF;
  RETURN NULL;
END;
$$;
CREATE TRIGGER game_auth_identity_cursor AFTER INSERT OR UPDATE OR DELETE ON game_identities
FOR EACH ROW EXECUTE FUNCTION game_auth_identity_cursor();

CREATE FUNCTION game_auth_application_mutation() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM id FROM users WHERE id=OLD.user_id FOR UPDATE;
    PERFORM game_auth_next_whitelist_version();
    RETURN OLD;
  END IF;
  PERFORM id FROM users WHERE id=NEW.user_id FOR UPDATE;
  IF TG_OP = 'UPDATE' THEN
    IF NEW.user_id IS DISTINCT FROM OLD.user_id THEN
      RAISE EXCEPTION 'immutable application owner';
    END IF;
    IF NEW.minecraft_nickname IS DISTINCT FROM OLD.minecraft_nickname
       OR NEW.minecraft_nickname_normalized IS DISTINCT FROM OLD.minecraft_nickname_normalized
       OR NEW.client_type IS DISTINCT FROM OLD.client_type
       OR NEW.status IS DISTINCT FROM OLD.status THEN
      UPDATE game_identities SET authentication_generation=authentication_generation+1 WHERE user_id=NEW.user_id;
      PERFORM game_auth_next_whitelist_version();
    END IF;
  ELSE
    PERFORM game_auth_next_whitelist_version();
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER game_auth_application_mutation BEFORE INSERT OR UPDATE OR DELETE ON applications
FOR EACH ROW EXECUTE FUNCTION game_auth_application_mutation();

CREATE FUNCTION game_auth_create_identity() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO game_identities(user_id) VALUES (NEW.user_id);
  RETURN NULL;
END;
$$;
CREATE TRIGGER game_auth_create_identity AFTER INSERT ON applications
FOR EACH ROW EXECUTE FUNCTION game_auth_create_identity();
-- Cracked and unbound licensed applications both have durable identity rows.
INSERT INTO game_identities(user_id) SELECT user_id FROM applications;

CREATE FUNCTION game_auth_credential_mutation() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE owner_id BIGINT;
BEGIN
  IF TG_OP = 'DELETE' THEN owner_id := OLD.user_id;
  ELSE owner_id := NEW.user_id;
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.user_id IS DISTINCT FROM OLD.user_id THEN
    RAISE EXCEPTION 'immutable credential owner';
  END IF;
  PERFORM id FROM users WHERE id=owner_id FOR UPDATE;
  -- Include same-hash resets, credential creation, and credential deletion.
  UPDATE game_identities SET authentication_generation=authentication_generation+1 WHERE user_id=owner_id;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER game_auth_credential_mutation BEFORE INSERT OR UPDATE OR DELETE ON password_credentials
FOR EACH ROW EXECUTE FUNCTION game_auth_credential_mutation();

-- identity mutations lock users first, even without a repository transaction.
-- callers may lock affected users by id before dependent changes and commit.
-- repository paths follow this order; cascades retain the parent lock.
-- raw identity dml cannot wait on owner locks; nowait enforces this.
-- functions use caller permissions, not privileged access.
CREATE FUNCTION game_auth_set_identity_uuid(owner_id BIGINT, replacement_uuid UUID) RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
DECLARE changed BIGINT;
BEGIN
  PERFORM id FROM users WHERE id=owner_id FOR UPDATE;
  UPDATE game_identities SET licensed_mojang_uuid=replacement_uuid WHERE user_id=owner_id;
  GET DIAGNOSTICS changed = ROW_COUNT;
  RETURN changed = 1;
END;
$$;

CREATE FUNCTION game_auth_delete_identity(owner_id BIGINT) RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
DECLARE changed BIGINT;
BEGIN
  PERFORM id FROM users WHERE id=owner_id FOR UPDATE;
  DELETE FROM game_identities WHERE user_id=owner_id;
  GET DIAGNOSTICS changed = ROW_COUNT;
  RETURN changed = 1;
END;
$$;

-- reentrant when the repository already owns the user. catch only the UUID
-- uniqueness race; every unrelated query/lock failure remains internal.
CREATE FUNCTION game_auth_bind_premium(owner_id BIGINT, asserted_uuid UUID) RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
DECLARE changed BIGINT; conflict_name TEXT;
BEGIN
  PERFORM id FROM users WHERE id=owner_id FOR UPDATE;
  UPDATE game_identities SET licensed_mojang_uuid=asserted_uuid
  WHERE user_id=owner_id AND (licensed_mojang_uuid IS NULL OR licensed_mojang_uuid=asserted_uuid);
  GET DIAGNOSTICS changed = ROW_COUNT;
  RETURN changed = 1;
EXCEPTION WHEN unique_violation THEN
  GET STACKED DIAGNOSTICS conflict_name = CONSTRAINT_NAME;
  IF conflict_name = 'game_identities_licensed_mojang_uuid_key' THEN RETURN FALSE; END IF;
  RAISE;
END;
$$;

-- proposed cleanup, not approved or scheduled.
-- backend owner may run at most once per minute.
-- delete up to 1,000 expired leases and 1,000 audit rows older than 7 days.
-- owner approval and scheduling are still required.
