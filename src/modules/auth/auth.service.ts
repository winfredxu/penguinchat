import type { Pool } from "pg";
import type { Config } from "../../config.js";
import { AppError } from "../../lib/errors.js";
import { hashPassword, verifyPassword } from "./password.js";
import { issueTokens, verifyRefresh } from "./tokens.js";
import {
  findById,
  findByUsername,
  insertUser,
  toPublic,
  updateUser,
  type PublicUser,
} from "./auth.repo.js";

export interface AuthResult {
  user: PublicUser;
  tokens: { accessToken: string; refreshToken: string };
}

export async function register(
  pool: Pool,
  cfg: Config,
  input: { username: string; display_name: string; password: string }
): Promise<AuthResult> {
  const existing = await findByUsername(pool, input.username);
  if (existing) throw new AppError(409, "username_taken", "Username already taken");
  const password_hash = await hashPassword(input.password);
  const user = await insertUser(pool, {
    username: input.username,
    display_name: input.display_name,
    password_hash,
  });
  return { user: toPublic(user), tokens: issueTokens(user.id, cfg) };
}

export async function login(
  pool: Pool,
  cfg: Config,
  input: { username: string; password: string }
): Promise<AuthResult> {
  const user = await findByUsername(pool, input.username);
  if (!user) throw new AppError(401, "invalid_credentials", "Invalid username or password");
  const ok = await verifyPassword(user.password_hash, input.password);
  if (!ok) throw new AppError(401, "invalid_credentials", "Invalid username or password");
  return { user: toPublic(user), tokens: issueTokens(user.id, cfg) };
}

export async function refresh(
  pool: Pool,
  cfg: Config,
  refreshToken: string
): Promise<{ tokens: { accessToken: string; refreshToken: string } }> {
  let sub: string;
  try {
    sub = verifyRefresh(refreshToken, cfg).sub;
  } catch {
    throw new AppError(401, "invalid_token", "Invalid refresh token");
  }
  const user = await findById(pool, sub);
  if (!user) throw new AppError(401, "invalid_token", "Invalid refresh token");
  // Rotation: issue a brand-new pair every refresh.
  return { tokens: issueTokens(user.id, cfg) };
}

export async function getMe(pool: Pool, userId: string): Promise<PublicUser> {
  const user = await findById(pool, userId);
  if (!user) throw new AppError(404, "not_found", "User not found");
  return toPublic(user);
}

export async function updateMe(
  pool: Pool,
  userId: string,
  fields: { display_name?: string; signature?: string; avatar_url?: string }
): Promise<PublicUser> {
  const user = await updateUser(pool, userId, fields);
  return toPublic(user);
}
