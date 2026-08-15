import type { AuthResult, ChatMessage, Contact, FriendRequest, Tokens, User } from "./types";

const API_ROOT = import.meta.env.VITE_API_URL ?? "/api";
let tokens: Tokens | null = null;

export class ApiError extends Error {
  constructor(public status: number, public code: string, message: string) {
    super(message);
  }
}

export function setTokens(next: Tokens | null): void {
  tokens = next;
  if (next) sessionStorage.setItem("penguinchat.tokens", JSON.stringify(next));
  else sessionStorage.removeItem("penguinchat.tokens");
}

export function getTokens(): Tokens | null {
  if (tokens) return tokens;
  const raw = sessionStorage.getItem("penguinchat.tokens");
  if (!raw) return null;
  try { tokens = JSON.parse(raw) as Tokens; } catch { sessionStorage.removeItem("penguinchat.tokens"); }
  return tokens;
}

async function request<T>(path: string, init: RequestInit = {}, retry = true): Promise<T> {
  const current = getTokens();
  const response = await fetch(`${API_ROOT}${path}`, {
    ...init,
    headers: {
      ...(init.body ? { "Content-Type": "application/json" } : {}),
      ...(current?.accessToken ? { Authorization: `Bearer ${current.accessToken}` } : {}),
      ...init.headers,
    },
  });
  if (response.status === 401 && retry && current?.refreshToken && path !== "/auth/refresh") {
    try {
      const refreshed = await request<{ tokens: Tokens }>("/auth/refresh", {
        method: "POST", body: JSON.stringify({ refreshToken: current.refreshToken }),
      }, false);
      setTokens(refreshed.tokens);
      return request<T>(path, init, false);
    } catch { setTokens(null); }
  }
  if (!response.ok) {
    const payload = await response.json().catch(() => ({ error: "request_failed", message: response.statusText }));
    throw new ApiError(response.status, payload.error ?? "request_failed", payload.message ?? "请求失败");
  }
  return response.json() as Promise<T>;
}

export const api = {
  login: (username: string, password: string) => request<AuthResult>("/auth/login", { method: "POST", body: JSON.stringify({ username, password }) }),
  register: (username: string, display_name: string, password: string) => request<AuthResult>("/auth/register", { method: "POST", body: JSON.stringify({ username, display_name, password }) }),
  me: () => request<{ user: User }>("/me"),
  contacts: () => request<Contact[]>("/contacts"),
  requests: () => request<FriendRequest[]>("/friend-requests"),
  sendRequest: (username: string, message: string) => request<{ request: FriendRequest }>("/friend-requests", { method: "POST", body: JSON.stringify({ username, message: message || undefined }) }),
  acceptRequest: (id: string) => request<{ friendId: string }>(`/friend-requests/${id}/accept`, { method: "POST" }),
  declineRequest: (id: string) => request<{ ok: boolean }>(`/friend-requests/${id}/decline`, { method: "POST" }),
  history: (peerId: string) => request<{ messages: ChatMessage[] }>(`/conversations/${peerId}/messages?limit=100`),
};
