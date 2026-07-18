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
  await Promise.all([c.pub.quit(), c.sub.quit(), c.general.quit()]);
}
