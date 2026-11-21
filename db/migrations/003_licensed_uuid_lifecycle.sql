-- track app revision outside the whitelist cursor
-- keep revision across app deletion and recreation
ALTER TABLE users ADD COLUMN application_revision BIGINT NOT NULL DEFAULT 1
  CHECK (application_revision > 0);

CREATE FUNCTION application_revision_dependent_mutation() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE owner_id BIGINT;
BEGIN
  IF TG_OP = 'DELETE' THEN owner_id := OLD.user_id;
  ELSE owner_id := NEW.user_id;
  END IF;
  UPDATE users SET application_revision = application_revision + 1
  WHERE id = owner_id;
  RETURN NULL;
END;
$$;

-- before triggers lock the owner, after triggers reuse it
-- repos lock all owners first, identity revision runs before cursor update
CREATE TRIGGER application_revision_application AFTER INSERT OR UPDATE OR DELETE ON applications
FOR EACH ROW EXECUTE FUNCTION application_revision_dependent_mutation();
CREATE TRIGGER application_revision_identity AFTER INSERT OR UPDATE OR DELETE ON game_identities
FOR EACH ROW EXECUTE FUNCTION application_revision_dependent_mutation();
CREATE TRIGGER application_revision_credential AFTER INSERT OR UPDATE OR DELETE ON password_credentials
FOR EACH ROW EXECUTE FUNCTION application_revision_dependent_mutation();

CREATE FUNCTION application_revision_discord_mutation() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE users SET application_revision = application_revision + 1
  WHERE id = NEW.id;
  RETURN NULL;
END;
$$;

-- revision-only updates don't trigger discord_id changes
CREATE TRIGGER application_revision_discord AFTER UPDATE OF discord_id ON users
FOR EACH ROW WHEN (OLD.discord_id IS DISTINCT FROM NEW.discord_id)
EXECUTE FUNCTION application_revision_discord_mutation();

-- not an auth or replacement check, call after locked binding validation
-- in_use must abort the whole command
CREATE FUNCTION application_set_licensed_uuid(owner_id BIGINT, replacement_uuid UUID)
RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE conflict_name TEXT;
BEGIN
  PERFORM id FROM users WHERE id=owner_id FOR UPDATE;
  IF NOT EXISTS (SELECT 1 FROM game_identities WHERE user_id=owner_id) THEN
    RETURN 'missing';
  END IF;
  UPDATE game_identities SET licensed_mojang_uuid=replacement_uuid
    WHERE user_id=owner_id AND licensed_mojang_uuid IS DISTINCT FROM replacement_uuid;
  RETURN 'updated';
EXCEPTION WHEN unique_violation THEN
  GET STACKED DIAGNOSTICS conflict_name = CONSTRAINT_NAME;
  IF conflict_name = 'game_identities_licensed_mojang_uuid_key' THEN
    RETURN 'in_use';
  END IF;
  RAISE;
END;
$$;
