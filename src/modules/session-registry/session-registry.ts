/**
 * Cross-instance live-event fan-out. In Plan 1 this is a no-op; Plan 2 replaces
 * the implementation with a Redis pub/sub version. Consumers depend only on the
 * interface so no consumer changes when the real one lands.
 */
export interface SessionRegistry {
  notify(userId: string, event: string, payload: unknown): Promise<void>;
}

export class NoopSessionRegistry implements SessionRegistry {
  async notify(): Promise<void> {
    // no-op in Plan 1
  }
}
