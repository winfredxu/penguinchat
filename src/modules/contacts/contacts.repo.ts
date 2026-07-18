import type { Pool } from "pg";
import type { PublicUser } from "../auth/auth.repo.js";

export interface FriendRequestRow {
  id: string;
  from_user: string;
  to_user: string;
  message: string | null;
  status: "pending" | "accepted" | "declined";
  created_at: string;
}

export async function insertRequest(
  pool: Pool,
  fromUser: string,
  toUser: string,
  message: string | null
): Promise<FriendRequestRow> {
  const res = await pool.query<FriendRequestRow>(
    `INSERT INTO friend_requests (from_user, to_user, message, status)
     VALUES ($1, $2, $3, 'pending') RETURNING *`,
    [fromUser, toUser, message]
  );
  return res.rows[0];
}

export async function findPendingBetween(
  pool: Pool,
  fromUser: string,
  toUser: string
): Promise<FriendRequestRow | null> {
  const res = await pool.query<FriendRequestRow>(
    `SELECT * FROM friend_requests
     WHERE from_user = $1 AND to_user = $2 AND status = 'pending'`,
    [fromUser, toUser]
  );
  return res.rows[0] ?? null;
}

export async function listIncomingPending(pool: Pool, userId: string): Promise<FriendRequestRow[]> {
  const res = await pool.query<FriendRequestRow>(
    `SELECT * FROM friend_requests
     WHERE to_user = $1 AND status = 'pending' ORDER BY created_at DESC`,
    [userId]
  );
  return res.rows;
}

export async function findRequestById(pool: Pool, id: string): Promise<FriendRequestRow | null> {
  const res = await pool.query<FriendRequestRow>("SELECT * FROM friend_requests WHERE id = $1", [id]);
  return res.rows[0] ?? null;
}

export async function setRequestStatus(
  pool: Pool,
  id: string,
  status: "accepted" | "declined"
): Promise<void> {
  await pool.query("UPDATE friend_requests SET status = $2 WHERE id = $1", [id, status]);
}

/** Insert friendship as an ordered pair (user_a < user_b). Idempotent. */
export async function insertFriendship(pool: Pool, x: string, y: string): Promise<void> {
  const [a, b] = x < y ? [x, y] : [y, x];
  await pool.query(
    `INSERT INTO friendships (user_a, user_b) VALUES ($1, $2)
     ON CONFLICT (user_a, user_b) DO NOTHING`,
    [a, b]
  );
}

export async function areFriends(pool: Pool, x: string, y: string): Promise<boolean> {
  const [a, b] = x < y ? [x, y] : [y, x];
  const res = await pool.query(
    "SELECT 1 FROM friendships WHERE user_a = $1 AND user_b = $2",
    [a, b]
  );
  return res.rowCount! > 0;
}

export async function listFriends(pool: Pool, userId: string): Promise<PublicUser[]> {
  const res = await pool.query<PublicUser>(
    `SELECT u.id, u.username, u.display_name, u.avatar_url, u.signature, u.created_at
     FROM friendships f
     JOIN users u
       ON u.id = CASE WHEN f.user_a = $1 THEN f.user_b ELSE f.user_a END
     WHERE f.user_a = $1 OR f.user_b = $1
     ORDER BY u.display_name`,
    [userId]
  );
  return res.rows;
}
