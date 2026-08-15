import type { Pool } from "pg";
import type { Config } from "../../config.js";
import { AppError } from "../../lib/errors.js";
import { hashPassword, verifyPassword } from "./password.js";
import { issueTokens, verifyRefresh } from "./tokens.js";
import {
  findById,
  findByUsername,
  insertRefreshToken,
  insertUser,
  getRefreshToken,
  revokeAllRefreshTokens,
  revokeRefreshToken,
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
  const tokens = issueTokens(user.id, cfg);
  await insertRefreshToken(pool, { jti: tokens.jti, userId: user.id });
  return { user: toPublic(user), tokens: { accessToken: tokens.accessToken, refreshToken: tokens.refreshToken } };
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
  const tokens = issueTokens(user.id, cfg);
  await insertRefreshToken(pool, { jti: tokens.jti, userId: user.id });
  return { user: toPublic(user), tokens: { accessToken: tokens.accessToken, refreshToken: tokens.refreshToken } };
}

export async function refresh(
  pool: Pool,
  cfg: Config,
  refreshToken: string
): Promise<{ tokens: { accessToken: string; refreshToken: string } }> {
  let sub: string;
  let jti: string;
  try {
    ({ sub, jti } = verifyRefresh(refreshToken, cfg));
  } catch {
    throw new AppError(401, "invalid_token", "Invalid refresh token");
  }
  const user = await findById(pool, sub);
  if (!user) throw new AppError(401, "invalid_token", "Invalid refresh token");
  const stored = await getRefreshToken(pool, jti);
  if (!stored) throw new AppError(401, "invalid_token", "Invalid refresh token");
  if (stored.revoked) {
    // Reuse detected: a rotated-out (revoked) token was presented again. Assume
    // compromise and revoke every device's refresh token for this user (FU-1).
    await revokeAllRefreshTokens(pool, sub);
    throw new AppError(401, "invalid_token", "Invalid refresh token");
  }
  // Rotate: revoke the presented token, issue a fresh pair with a new jti.
  await revokeRefreshToken(pool, jti);
  const tokens = issueTokens(user.id, cfg);
  await insertRefreshToken(pool, { jti: tokens.jti, userId: user.id });
  return { tokens: { accessToken: tokens.accessToken, refreshToken: tokens.refreshToken } };
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
