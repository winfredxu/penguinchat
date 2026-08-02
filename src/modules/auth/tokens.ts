import jwt from "jsonwebtoken";
import { randomUUID } from "node:crypto";

export interface TokenConfig {
  jwtAccessSecret: string;
  jwtRefreshSecret: string;
  accessTtl: string;
  refreshTtl: string;
}

export interface IssuedTokens {
  accessToken: string;
  refreshToken: string;
  /** The refresh token's jti - persist it for rotation + reuse detection (FU-1). */
  jti: string;
}

export function issueTokens(userId: string, cfg: TokenConfig): IssuedTokens {
  const accessToken = jwt.sign({ sub: userId, type: "access" }, cfg.jwtAccessSecret, {
    expiresIn: cfg.accessTtl as jwt.SignOptions["expiresIn"],
  });
  const jti = randomUUID();
  const refreshToken = jwt.sign({ sub: userId, type: "refresh", jti }, cfg.jwtRefreshSecret, {
    expiresIn: cfg.refreshTtl as jwt.SignOptions["expiresIn"],
  });
  return { accessToken, refreshToken, jti };
}

export function verifyAccess(token: string, cfg: TokenConfig): { sub: string } {
  const payload = jwt.verify(token, cfg.jwtAccessSecret) as jwt.JwtPayload;
  // FU-7: defense-in-depth. A refresh token signed with a (misconfigured) shared
  // secret must still be rejected as an access token.
  if (payload.type !== "access") throw new Error("wrong token type");
  if (!payload.sub) throw new Error("missing sub");
  return { sub: payload.sub };
}

export function verifyRefresh(token: string, cfg: TokenConfig): { sub: string; jti: string } {
  const payload = jwt.verify(token, cfg.jwtRefreshSecret) as jwt.JwtPayload;
  if (payload.type !== "refresh") throw new Error("wrong token type");
  if (!payload.sub || !payload.jti) throw new Error("missing claims");
  return { sub: payload.sub, jti: payload.jti as string };
}
