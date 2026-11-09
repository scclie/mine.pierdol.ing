CREATE TYPE application_status AS ENUM (
  'pending', 'approved', 'rejected_retryable', 'rejected_final', 'banned'
);
CREATE TYPE minecraft_client_type AS ENUM ('licensed', 'cracked');

CREATE TABLE users (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  discord_id TEXT NOT NULL UNIQUE,
  discord_username TEXT NOT NULL,
  discord_global_name TEXT,
  discord_avatar_hash TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE applications (
  user_id BIGINT PRIMARY KEY REFERENCES users(id) ON DELETE RESTRICT,
  minecraft_nickname TEXT NOT NULL UNIQUE,
  minecraft_nickname_normalized TEXT NOT NULL UNIQUE,
  client_type minecraft_client_type NOT NULL,
  about_me TEXT NOT NULL,
  discovery_source TEXT NOT NULL,
  status application_status NOT NULL DEFAULT 'pending',
  decision_reason TEXT,
  submitted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  decided_at TIMESTAMPTZ,
  decided_by_user_id BIGINT REFERENCES users(id) ON DELETE RESTRICT,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK ((status IN ('rejected_retryable', 'rejected_final', 'banned')) = (decision_reason IS NOT NULL))
);

CREATE TABLE password_credentials (
  user_id BIGINT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  password_hash TEXT NOT NULL,
  changed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE web_sessions (
  id UUID PRIMARY KEY,
  user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash BYTEA NOT NULL UNIQUE,
  csrf_token_hash BYTEA NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  revoked_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE oauth_states (
  state_hash BYTEA PRIMARY KEY,
  pkce_verifier TEXT NOT NULL,
  return_path TEXT NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE audit_log (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  actor_user_id BIGINT REFERENCES users(id) ON DELETE RESTRICT,
  subject_user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  action TEXT NOT NULL,
  old_value JSONB,
  new_value JSONB,
  reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX applications_status_submitted_at_idx ON applications(status, submitted_at);
CREATE INDEX applications_minecraft_nickname_normalized_idx ON applications(minecraft_nickname_normalized);
CREATE INDEX web_sessions_user_id_expires_at_idx ON web_sessions(user_id, expires_at);
CREATE INDEX audit_log_subject_user_id_created_at_idx ON audit_log(subject_user_id, created_at DESC);
