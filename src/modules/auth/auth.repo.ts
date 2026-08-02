import type { Pool } from "pg";

export interface UserRow {
  id: string;
  username: string;
  display_name: string;
  password_hash: string;
  avatar_url: string | null;
  signature: string | null;
  created_at: string;
}

export interface PublicUser {
  id: string;
  username: string;
  display_name: string;
  avatar_url: string | null;
  signature: string | null;
  created_at: string;
}

export function toPublic(u: UserRow): PublicUser {
  const { password_hash, ...rest } = u;
  void password_hash;
  return rest;
}

export async function insertUser(
  pool: Pool,
  input: { username: string; display_name: string; password_hash: string }
): Promise<UserRow> {
  const res = await pool.query<UserRow>(
    `INSERT INTO users (username, display_name, password_hash)
     VALUES ($1, $2, $3) RETURNING *`,
    [input.username, input.display_name, input.password_hash]
  );
  return res.rows[0];
}

export async function findByUsername(pool: Pool, username: string): Promise<UserRow | null> {
  const res = await pool.query<UserRow>("SELECT * FROM users WHERE username = $1", [username]);
  return res.rows[0] ?? null;
}

export async function findById(pool: Pool, id: string): Promise<UserRow | null> {
  const res = await pool.query<UserRow>("SELECT * FROM users WHERE id = $1", [id]);
  return res.rows[0] ?? null;
}

export async function updateUser(
  pool: Pool,
  id: string,
  fields: { display_name?: string; signature?: string; avatar_url?: string }
): Promise<UserRow> {
  const sets: string[] = [];
  const vals: unknown[] = [];
  let i = 1;
  for (const [k, v] of Object.entries(fields)) {
    if (v !== undefined) {
      sets.push(`${k} = $${i++}`);
      vals.push(v);
    }
  }
  if (sets.length === 0) {
    const cur = await findById(pool, id);
    return cur as UserRow;
  }
  vals.push(id);
  const res = await pool.query<UserRow>(
    `UPDATE users SET ${sets.join(", ")} WHERE id = $${i} RETURNING *`,
    vals
  );
  return res.rows[0];
}

// --- Refresh-token rotation (FU-1) ---

export async function insertRefreshToken(
  pool: Pool,
  input: { jti: string; userId: string }
): Promise<void> {
  await pool.query(
    `INSERT INTO refresh_tokens (jti, user_id) VALUES ($1, $2)
     ON CONFLICT (jti) DO NOTHING`,
    [input.jti, input.userId]
  );
}

export async function getRefreshToken(
  pool: Pool,
  jti: string
): Promise<{ revoked: boolean } | null> {
  const res = await pool.query<{ revoked: boolean }>(
    "SELECT revoked FROM refresh_tokens WHERE jti = $1",
    [jti]
  );
  return res.rows[0] ?? null;
}

export async function revokeRefreshToken(pool: Pool, jti: string): Promise<void> {
  await pool.query("UPDATE refresh_tokens SET revoked = true WHERE jti = $1", [jti]);
}

export async function revokeAllRefreshTokens(pool: Pool, userId: string): Promise<void> {
  await pool.query("UPDATE refresh_tokens SET revoked = true WHERE user_id = $1", [userId]);
}
