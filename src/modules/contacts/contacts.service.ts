import type { Pool } from "pg";
import { AppError } from "../../lib/errors.js";
import type { SessionRegistry } from "../session-registry/session-registry.js";
import type { PresenceReader, PresenceStatus } from "../presence/presence.service.js";
import { findById, findByUsername, type PublicUser } from "../auth/auth.repo.js";
import {
  areFriends,
  findPendingBetween,
  findRequestById,
  insertFriendship,
  insertRequest,
  listFriends,
  listIncomingPending,
  setRequestStatus,
  type FriendRequestRow,
} from "./contacts.repo.js";

export type Contact = PublicUser & { presence: "online" | "away" | "offline" };

export async function sendRequest(
  pool: Pool,
  registry: SessionRegistry,
  fromUser: string,
  targetUsername: string,
  message: string | null
): Promise<FriendRequestRow> {
  const target = await findByUsername(pool, targetUsername);
  if (!target) throw new AppError(404, "not_found", "No such user");
  if (target.id === fromUser) throw new AppError(400, "self_request", "Cannot add yourself");
  if (await areFriends(pool, fromUser, target.id))
    throw new AppError(409, "already_friends", "Already friends");
  const dup = await findPendingBetween(pool, fromUser, target.id);
  if (dup) throw new AppError(409, "request_exists", "Request already pending");

  const request = await insertRequest(pool, fromUser, target.id, message);
  await registry.notify(target.id, "friend:request", { request });
  return request;
}

export async function listRequests(pool: Pool, userId: string): Promise<FriendRequestRow[]> {
  return listIncomingPending(pool, userId);
}

export async function acceptRequest(
  pool: Pool,
  registry: SessionRegistry,
  userId: string,
  requestId: string
): Promise<{ friendId: string }> {
  const req = await findRequestById(pool, requestId);
  if (!req || req.status !== "pending") throw new AppError(404, "not_found", "No pending request");
  if (req.to_user !== userId) throw new AppError(403, "forbidden", "Not your request to accept");
  await insertFriendship(pool, req.from_user, req.to_user);
  await setRequestStatus(pool, requestId, "accepted");
  await registry.notify(req.from_user, "friend:accepted", { friendId: req.to_user });
  return { friendId: req.from_user };
}

export async function declineRequest(
  pool: Pool,
  userId: string,
  requestId: string
): Promise<void> {
  const req = await findRequestById(pool, requestId);
  if (!req || req.status !== "pending") throw new AppError(404, "not_found", "No pending request");
  if (req.to_user !== userId) throw new AppError(403, "forbidden", "Not your request to decline");
  await setRequestStatus(pool, requestId, "declined");
}

export async function listContacts(
  pool: Pool,
  presence: PresenceReader,
  userId: string
): Promise<Contact[]> {
  const friends = await listFriends(pool, userId);
  if (friends.length === 0) return [];
  const statusMap = await presence.getMany(friends.map((f) => f.id));
  return friends.map((f) => ({
    ...f,
    presence: statusMap.get(f.id) ?? ("offline" as PresenceStatus),
  }));
}

// Re-export so routes need only import this module.
export { findById };
