import type { Pool } from "pg";
import { AppError } from "../../lib/errors.js";
import { conversationId } from "../../lib/ids.js";
import { areFriends } from "../contacts/contacts.repo.js";
import {
  insert,
  listByConversation,
  markDelivered as repoMarkDelivered,
  markRead as repoMarkRead,
  type MessageRow,
} from "./messaging.repo.js";

export type { MessageRow } from "./messaging.repo.js";

export async function send(
  pool: Pool,
  senderId: string,
  input: { toUserId: string; body: string }
): Promise<MessageRow> {
  if (!(await areFriends(pool, senderId, input.toUserId))) {
    throw new AppError(403, "not_friends", "You can only message friends");
  }
  const conversation = conversationId(senderId, input.toUserId);
  return insert(pool, {
    conversation,
    senderId,
    recipientId: input.toUserId,
    body: input.body,
  });
}

export async function markDelivered(pool: Pool, messageId: string): Promise<MessageRow | null> {
  return repoMarkDelivered(pool, messageId);
}

export async function markRead(
  pool: Pool,
  readerId: string,
  peerId: string,
  upToMessageId: string
): Promise<{ conversation: string }> {
  if (!(await areFriends(pool, readerId, peerId))) {
    throw new AppError(403, "not_friends", "You can only read your own conversations");
  }
  const conversation = conversationId(readerId, peerId);
  await repoMarkRead(pool, conversation, readerId, upToMessageId);
  return { conversation };
}

export async function listHistory(
  pool: Pool,
  userId: string,
  peerId: string,
  opts: { before?: string; limit?: number } = {}
): Promise<MessageRow[]> {
  if (!(await areFriends(pool, userId, peerId))) {
    throw new AppError(403, "not_friends", "You can only read your own conversations");
  }
  const conversation = conversationId(userId, peerId);
  const limit = Math.max(1, Math.min(100, opts.limit ?? 50));
  return listByConversation(pool, conversation, { before: opts.before, limit });
}
