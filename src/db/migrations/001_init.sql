CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS users (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  username      text UNIQUE NOT NULL,
  display_name  text NOT NULL,
  password_hash text NOT NULL,
  avatar_url    text,
  signature     text,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS friendships (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_a     uuid NOT NULL REFERENCES users(id),
  user_b     uuid NOT NULL REFERENCES users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_a, user_b),
  CHECK (user_a < user_b)
);

CREATE TABLE IF NOT EXISTS friend_requests (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  from_user  uuid NOT NULL REFERENCES users(id),
  to_user    uuid NOT NULL REFERENCES users(id),
  message    text,
  status     text NOT NULL CHECK (status IN ('pending','accepted','declined')),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS friend_requests_pending_uniq
  ON friend_requests (from_user, to_user) WHERE status = 'pending';

CREATE TABLE IF NOT EXISTS messages (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation uuid NOT NULL,
  sender_id    uuid NOT NULL REFERENCES users(id),
  recipient_id uuid NOT NULL REFERENCES users(id),
  body         text NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  delivered_at timestamptz,
  read_at      timestamptz
);

CREATE INDEX IF NOT EXISTS messages_conversation_created_idx
  ON messages (conversation, created_at);
