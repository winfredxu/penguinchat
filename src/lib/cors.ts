/**
 * CORS origin option shared by the REST app (app.ts) and the Socket.IO gateway
 * (FU-3 / FU-15). An empty list preserves the dev default (reflect any origin);
 * a non-empty list is an allowlist enforced for both transports.
 */
export type CorsOriginOption = true | CorsOriginFn;

type CorsOriginFn = (
  origin: string | undefined,
  callback: (err: Error | null, origin: boolean | string | string[]) => void
) => void;

export function corsOriginOption(origins: string[]): CorsOriginOption {
  if (origins.length === 0) return true; // dev: reflect any origin
  return (origin, callback) => {
    // No Origin header = same-origin / non-CORS request: allow.
    if (!origin || origins.includes(origin)) return callback(null, true);
    return callback(new Error("Not allowed by CORS"), false);
  };
}
