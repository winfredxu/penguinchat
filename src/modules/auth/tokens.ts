import jwt from "jsonwebtoken";

export interface TokenConfig {
  jwtAccessSecret: string;
  jwtRefreshSecret: string;
  accessTtl: string;
  refreshTtl: string;
}

export function issueTokens(userId: string, cfg: TokenConfig) {
  const accessToken = jwt.sign({ sub: userId }, cfg.jwtAccessSecret, {
    expiresIn: cfg.accessTtl as jwt.SignOptions["expiresIn"],
  });
  const refreshToken = jwt.sign({ sub: userId }, cfg.jwtRefreshSecret, {
    expiresIn: cfg.refreshTtl as jwt.SignOptions["expiresIn"],
  });
  return { accessToken, refreshToken };
}

export function verifyAccess(token: string, cfg: TokenConfig): { sub: string } {
  return jwt.verify(token, cfg.jwtAccessSecret) as { sub: string };
}

export function verifyRefresh(token: string, cfg: TokenConfig): { sub: string } {
  return jwt.verify(token, cfg.jwtRefreshSecret) as { sub: string };
}
