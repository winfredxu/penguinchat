import { createClient, type RedisClientType } from "redis";

export interface RedisClients {
  pub: RedisClientType;
  sub: RedisClientType;
  general: RedisClientType;
}

export async function createRedisClients(redisUrl: string): Promise<RedisClients> {
  const pub = createClient({ url: redisUrl }) as RedisClientType;
  const sub = pub.duplicate() as RedisClientType;
  const general = pub.duplicate() as RedisClientType;
  await Promise.all([pub.connect(), sub.connect(), general.connect()]);
  return { pub, sub, general };
}

export async function closeRedisClients(c: RedisClients): Promise<void> {
  // allSettled (FU-14): if one client is already in an error state, Promise.all
  // would reject on it and leave the other quits un-awaited, leaking connections.
  await Promise.allSettled([c.pub.quit(), c.sub.quit(), c.general.quit()]);
}
