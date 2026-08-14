import type { Pool } from "pg";

export async function resetDb(pool: Pool): Promise<void> {
  await pool.query(
    "TRUNCATE messages, friend_requests, friendships, refresh_tokens, users RESTART IDENTITY CASCADE"
  );
}
