import type { RedisClientType } from "redis";

export type PresenceStatus = "online" | "offline";

export interface PresenceReader {
  getMany(userIds: string[]): Promise<Map<string, PresenceStatus>>;
}

const key = (userId: string) => `presence:${userId}`;

export class PresenceService implements PresenceReader {
  constructor(private general: RedisClientType, private ttlSeconds = 30) {}

  async setOnline(userId: string): Promise<void> {
    await this.general.set(key(userId), "online", { EX: this.ttlSeconds });
  }

  async refresh(userId: string): Promise<void> {
    await this.general.expire(key(userId), this.ttlSeconds);
  }

  async clear(userId: string): Promise<void> {
    await this.general.del(key(userId));
  }

  async get(userId: string): Promise<PresenceStatus> {
    const v = await this.general.get(key(userId));
    return v === "online" ? "online" : "offline";
  }

  async getMany(userIds: string[]): Promise<Map<string, PresenceStatus>> {
    if (userIds.length === 0) return new Map();
    const keys = userIds.map(key);
    const vals = await this.general.mGet(keys);
    const out = new Map<string, PresenceStatus>();
    userIds.forEach((id, i) => {
      out.set(id, vals[i] === "online" ? "online" : "offline");
    });
    return out;
  }
}

export class NoopPresenceService implements PresenceReader {
  async getMany(userIds: string[]): Promise<Map<string, PresenceStatus>> {
    const m = new Map<string, PresenceStatus>();
    for (const id of userIds) m.set(id, "offline");
    return m;
  }
}
