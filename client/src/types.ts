export interface User {
  id: string;
  username: string;
  display_name: string;
  avatar_url: string | null;
  signature: string | null;
  created_at: string;
}

export interface Contact extends User {
  presence: "online" | "away" | "offline";
}

export interface FriendRequest {
  id: string;
  from_user: string;
  to_user: string;
  message: string | null;
  status: string;
  created_at: string;
  from_username?: string;
  from_display_name?: string;
}

export interface ChatMessage {
  id: string;
  conversation?: string;
  sender_id: string;
  recipient_id: string;
  body: string;
  created_at: string;
  delivered_at: string | null;
  read_at: string | null;
  clientMsgId?: string;
  pending?: boolean;
  failed?: boolean;
}

export interface Tokens { accessToken: string; refreshToken: string }
export interface AuthResult { user: User; tokens: Tokens }
