export interface Config {
  port: number;
  logLevel: string;
  databaseUrl: string;
  redisUrl: string;
  jwtAccessSecret: string;
  jwtRefreshSecret: string;
  accessTtl: string;
  refreshTtl: string;
  /** CORS allowlist for REST + Socket.IO. Empty = allow all (dev default). */
  corsOrigins: string[];
}

function required(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing required env var: ${name}`);
  return v;
}

export function loadConfig(): Config {
  const corsOriginsEnv = process.env.CORS_ORIGINS;
  return {
    port: Number(process.env.PORT ?? 3000),
    logLevel: process.env.LOG_LEVEL ?? "info",
    databaseUrl: required("DATABASE_URL"),
    redisUrl: required("REDIS_URL"),
    jwtAccessSecret: required("JWT_ACCESS_SECRET"),
    jwtRefreshSecret: required("JWT_REFRESH_SECRET"),
    accessTtl: process.env.ACCESS_TTL ?? "15m",
    refreshTtl: process.env.REFRESH_TTL ?? "30d",
    // Comma-separated allowlist, e.g. "https://app.example.com,http://localhost:5173".
    // Unset = allow all (dev). Set before the client ships to production.
    corsOrigins: corsOriginsEnv ? corsOriginsEnv.split(",").map((s) => s.trim()).filter(Boolean) : [],
  };
}
