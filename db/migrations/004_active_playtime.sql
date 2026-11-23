ALTER TABLE users ADD COLUMN active_seconds BIGINT NOT NULL DEFAULT 0
    CHECK (active_seconds >= 0);
