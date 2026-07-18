import { Pool } from "pg";
import { loadConfig } from "./config.js";
import { buildApp } from "./app.js";

async function main() {
  const config = loadConfig();
  const pool = new Pool({ connectionString: config.databaseUrl });
  const app = await buildApp({ pool, config });
  await app.listen({ port: config.port, host: "0.0.0.0" });
  // eslint-disable-next-line no-console
  console.log(`PenguinChat API listening on :${config.port}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
