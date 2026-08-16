ALTER TABLE messages
  ADD COLUMN IF NOT EXISTS client_msg_id text;

CREATE UNIQUE INDEX IF NOT EXISTS messages_sender_client_msg_uniq
  ON messages (sender_id, client_msg_id)
  WHERE client_msg_id IS NOT NULL;
