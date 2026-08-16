import type { Pool } from "pg";

export interface MessageRow {
  id: string;
  conversation: string;
  sender_id: string;
  recipient_id: string;
  body: string;
  created_at: string;
  delivered_at: string | null;
  read_at: string | null;
  client_msg_id: string | null;
}

// pg returns Date objects for timestamptz columns; normalize to ISO strings so
// the runtime values match the MessageRow contract (and so idempotent
// markDelivered calls return value-equal timestamps across invocations).
function asString(v: unknown): string | null {
  if (v == null) return null;
  if (v instanceof Date) return v.toISOString();
  return String(v);
}

function mapRow(r: {
  id: string;
  conversation: string;
  sender_id: string;
  recipient_id: string;
  body: string;
  created_at: unknown;
  delivered_at: unknown;
  read_at: unknown;
  client_msg_id: string | null;
}): MessageRow {
  return {
    id: r.id,
    conversation: r.conversation,
    sender_id: r.sender_id,
    recipient_id: r.recipient_id,
    body: r.body,
    created_at: asString(r.created_at) as string,
    delivered_at: asString(r.delivered_at),
    read_at: asString(r.read_at),
    client_msg_id: r.client_msg_id,
  };
}

export async function insert(
  pool: Pool,
  input: { conversation: string; senderId: string; recipientId: string; body: string }
): Promise<MessageRow> {
  const res = await pool.query(
    `INSERT INTO messages (conversation, sender_id, recipient_id, body)
     VALUES ($1, $2, $3, $4) RETURNING *`,
    [input.conversation, input.senderId, input.recipientId, input.body]
  );
  return mapRow(res.rows[0]);
}

export async function insertIdempotent(
  pool: Pool,
  input: {
    conversation: string;
    senderId: string;
    recipientId: string;
    body: string;
    clientMsgId: string;
  }
): Promise<{ message: MessageRow; inserted: boolean }> {
  const inserted = await pool.query(
    `INSERT INTO messages
       (conversation, sender_id, recipient_id, body, client_msg_id)
     VALUES ($1, $2, $3, $4, $5)
     ON CONFLICT (sender_id, client_msg_id)
       WHERE client_msg_id IS NOT NULL
       DO NOTHING
     RETURNING *`,
    [input.conversation, input.senderId, input.recipientId, input.body, input.clientMsgId]
  );
  if (inserted.rowCount) {
    return { message: mapRow(inserted.rows[0]), inserted: true };
  }

  const existing = await pool.query(
    `SELECT * FROM messages
     WHERE sender_id = $1 AND client_msg_id = $2`,
    [input.senderId, input.clientMsgId]
  );
  if (!existing.rowCount) {
    throw new Error("idempotent message insert lost its conflicting row");
  }
  return { message: mapRow(existing.rows[0]), inserted: false };
}

export async function findById(pool: Pool, messageId: string): Promise<MessageRow | null> {
  const res = await pool.query("SELECT * FROM messages WHERE id = $1", [messageId]);
  return res.rows[0] ? mapRow(res.rows[0]) : null;
}

/** Sets delivered_at = now() only if currently null (idempotent). Returns the row or null. */
export async function markDelivered(pool: Pool, messageId: string): Promise<MessageRow | null> {
  const res = await pool.query(
    `UPDATE messages SET delivered_at = now()
     WHERE id = $1 AND delivered_at IS NULL RETURNING *`,
    [messageId]
  );
  if (res.rowCount) return mapRow(res.rows[0]);
  // Either the message doesn't exist or it was already delivered - return current state.
  return findById(pool, messageId);
}

/** Marks read_at on the reader's received messages up to (and including) upToMessageId, by created_at. */
export async function markRead(
  pool: Pool,
  conversation: string,
  readerId: string,
  upToMessageId: string
): Promise<void> {
  await pool.query(
    `UPDATE messages SET read_at = now()
     WHERE conversation = $1
       AND recipient_id = $2
       AND read_at IS NULL
       AND created_at <= (SELECT created_at FROM messages WHERE id = $3)`,
    [conversation, readerId, upToMessageId]
  );
}

export async function listByConversation(
  pool: Pool,
  conversation: string,
  opts: { before?: string; limit: number }
): Promise<MessageRow[]> {
  const res = await pool.query(
    `SELECT * FROM messages
     WHERE conversation = $1 AND ($2::timestamptz IS NULL OR created_at < $2)
     ORDER BY created_at DESC
     LIMIT $3`,
    [conversation, opts.before ?? null, opts.limit]
  );
  return res.rows.map(mapRow);
}
