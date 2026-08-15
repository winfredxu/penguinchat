import { FormEvent, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { io, type Socket } from "socket.io-client";
import { api, ApiError, getTokens, setTokens } from "./api";
import type { AuthResult, ChatMessage, Contact, FriendRequest, User } from "./types";

function messageOf(error: unknown): string {
  if (error instanceof ApiError) return error.message;
  if (error instanceof Error) return error.message;
  return "操作失败，请稍后重试";
}

function Avatar({ user, small = false }: { user: Pick<User, "display_name" | "avatar_url">; small?: boolean }) {
  return user.avatar_url
    ? <img className={`avatar ${small ? "small" : ""}`} src={user.avatar_url} alt="" />
    : <span className={`avatar fallback ${small ? "small" : ""}`}>{user.display_name.slice(0, 1).toUpperCase()}</span>;
}

function AuthScreen({ onAuth }: { onAuth: (result: AuthResult) => void }) {
  const [registering, setRegistering] = useState(false);
  const [username, setUsername] = useState("");
  const [displayName, setDisplayName] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  async function submit(event: FormEvent) {
    event.preventDefault();
    setBusy(true); setError("");
    try {
      const result = registering
        ? await api.register(username.trim(), displayName.trim(), password)
        : await api.login(username.trim(), password);
      setTokens(result.tokens);
      onAuth(result);
    } catch (err) { setError(messageOf(err)); }
    finally { setBusy(false); }
  }

  return <main className="auth-page">
    <section className="brand-panel">
      <div className="brand-mark">🐧</div>
      <p className="eyebrow">PENGUINCHAT</p>
      <h1>和重要的人，<br />随时聊两句。</h1>
      <p className="brand-copy">轻巧、实时、专注的一对一聊天空间。</p>
      <div className="ice-orb orb-one" /><div className="ice-orb orb-two" />
    </section>
    <section className="auth-card-wrap">
      <form className="auth-card" onSubmit={submit}>
        <span className="mini-penguin">🐧</span>
        <h2>{registering ? "创建企鹅号" : "欢迎回来"}</h2>
        <p>{registering ? "注册后即可添加好友并开始聊天" : "登录你的 PenguinChat 账号"}</p>
        {error && <div className="notice error" role="alert">{error}</div>}
        <label>企鹅号<input autoFocus required minLength={3} maxLength={32} value={username} onChange={(e) => setUsername(e.target.value)} placeholder="例如 penguin_01" /></label>
        {registering && <label>昵称<input required minLength={1} maxLength={64} value={displayName} onChange={(e) => setDisplayName(e.target.value)} placeholder="大家怎么称呼你" /></label>}
        <label>密码<input required minLength={6} type="password" value={password} onChange={(e) => setPassword(e.target.value)} placeholder="至少 6 位" /></label>
        <button className="primary full" disabled={busy}>{busy ? "请稍候…" : registering ? "注册并进入" : "登录"}</button>
        <button className="text-button" type="button" onClick={() => { setRegistering(!registering); setError(""); }}>
          {registering ? "已有账号？直接登录" : "第一次来？创建账号"}
        </button>
      </form>
    </section>
  </main>;
}

export function App() {
  const [user, setUser] = useState<User | null>(null);
  const [booting, setBooting] = useState(Boolean(getTokens()));

  useEffect(() => {
    if (!getTokens()) return;
    api.me().then(({ user: me }) => setUser(me)).catch(() => setTokens(null)).finally(() => setBooting(false));
  }, []);

  if (booting) return <div className="splash"><span>🐧</span><p>PenguinChat 正在醒来…</p></div>;
  if (!user) return <AuthScreen onAuth={(result) => setUser(result.user)} />;
  return <ChatShell user={user} onLogout={() => { setTokens(null); setUser(null); }} />;
}

function ChatShell({ user, onLogout }: { user: User; onLogout: () => void }) {
  const [contacts, setContacts] = useState<Contact[]>([]);
  const [requests, setRequests] = useState<FriendRequest[]>([]);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [messages, setMessages] = useState<Record<string, ChatMessage[]>>({});
  const [unread, setUnread] = useState<Record<string, number>>({});
  const [typing, setTyping] = useState<Record<string, boolean>>({});
  const [compose, setCompose] = useState("");
  const [search, setSearch] = useState("");
  const [showPeople, setShowPeople] = useState(false);
  const [friendUsername, setFriendUsername] = useState("");
  const [friendNote, setFriendNote] = useState("");
  const [notice, setNotice] = useState("");
  const socketRef = useRef<Socket | null>(null);
  const selectedRef = useRef<string | null>(null);
  const messageEndRef = useRef<HTMLDivElement | null>(null);
  selectedRef.current = selectedId;

  const refreshPeople = useCallback(async () => {
    const [nextContacts, nextRequests] = await Promise.all([api.contacts(), api.requests()]);
    setContacts(nextContacts); setRequests(nextRequests);
  }, []);

  useEffect(() => { refreshPeople().catch((err) => setNotice(messageOf(err))); }, [refreshPeople]);

  useEffect(() => {
    const token = getTokens()?.accessToken;
    if (!token) return;
    const socket = io({ auth: { token } });
    socketRef.current = socket;
    const heartbeat = window.setInterval(() => socket.emit("presence:heartbeat"), 25_000);
    socket.on("connect_error", () => setNotice("实时连接失败，正在自动重连…"));
    socket.on("connect", () => setNotice(""));
    socket.on("presence:update", ({ userId, status }: { userId: string; status: Contact["presence"] }) => {
      setContacts((list) => list.map((contact) => contact.id === userId ? { ...contact, presence: status } : contact));
    });
    socket.on("friend:request", () => refreshPeople().catch(() => undefined));
    socket.on("friend:accepted", () => refreshPeople().catch(() => undefined));
    socket.on("typing", ({ fromUserId, isTyping }: { fromUserId: string; isTyping: boolean }) => setTyping((state) => ({ ...state, [fromUserId]: isTyping })));
    socket.on("message:new", ({ message }: { message: ChatMessage }) => {
      const peerId = message.sender_id;
      setMessages((all) => ({ ...all, [peerId]: [...(all[peerId] ?? []), message] }));
      socket.emit("message:delivered", { messageId: message.id });
      if (selectedRef.current === peerId) socket.emit("message:read", { peerId, upToMessageId: message.id });
      else setUnread((state) => ({ ...state, [peerId]: (state[peerId] ?? 0) + 1 }));
    });
    socket.on("message:delivered", ({ messageId, delivered_at }: { messageId: string; delivered_at: string }) => {
      setMessages((all) => Object.fromEntries(Object.entries(all).map(([peer, rows]) => [peer, rows.map((row) => row.id === messageId ? { ...row, delivered_at } : row)])));
    });
    socket.on("message:read", ({ upToMessageId }: { upToMessageId: string }) => {
      const now = new Date().toISOString();
      setMessages((all) => Object.fromEntries(Object.entries(all).map(([peer, rows]) => {
        const boundary = rows.find((row) => row.id === upToMessageId)?.created_at;
        return [peer, boundary ? rows.map((row) => row.sender_id === user.id && row.created_at <= boundary ? { ...row, read_at: row.read_at ?? now } : row) : rows];
      })));
    });
    return () => { window.clearInterval(heartbeat); socket.disconnect(); socketRef.current = null; };
  }, [refreshPeople, user.id]);

  const selectContact = useCallback(async (contact: Contact) => {
    setSelectedId(contact.id); setUnread((state) => ({ ...state, [contact.id]: 0 }));
    try {
      const { messages: history } = await api.history(contact.id);
      const ordered = [...history].reverse();
      setMessages((all) => ({ ...all, [contact.id]: ordered }));
      const latestReceived = [...ordered].reverse().find((row) => row.recipient_id === user.id && !row.read_at);
      if (latestReceived) socketRef.current?.emit("message:read", { peerId: contact.id, upToMessageId: latestReceived.id });
    } catch (err) { setNotice(messageOf(err)); }
  }, [user.id]);

  useEffect(() => { messageEndRef.current?.scrollIntoView({ behavior: "smooth" }); }, [messages, selectedId, typing]);

  const selected = contacts.find((contact) => contact.id === selectedId) ?? null;
  const filtered = useMemo(() => contacts.filter((contact) => `${contact.display_name} ${contact.username}`.toLowerCase().includes(search.toLowerCase())), [contacts, search]);

  function sendMessage(event: FormEvent) {
    event.preventDefault();
    const body = compose.trim();
    if (!selected || !body || !socketRef.current) return;
    const clientMsgId = crypto.randomUUID();
    const optimistic: ChatMessage = { id: clientMsgId, clientMsgId, sender_id: user.id, recipient_id: selected.id, body, created_at: new Date().toISOString(), delivered_at: null, read_at: null, pending: true };
    setMessages((all) => ({ ...all, [selected.id]: [...(all[selected.id] ?? []), optimistic] }));
    setCompose(""); socketRef.current.emit("typing:stop", { toUserId: selected.id });
    socketRef.current.timeout(8_000).emit("message:send", { toUserId: selected.id, body, clientMsgId }, (error: Error | null, ack: { id?: string; created_at?: string; error?: string }) => {
      setMessages((all) => ({ ...all, [selected.id]: (all[selected.id] ?? []).map((row) => row.clientMsgId === clientMsgId ? (error || ack?.error ? { ...row, pending: false, failed: true } : { ...row, id: ack.id!, created_at: ack.created_at!, pending: false }) : row) }));
    });
  }

  async function addFriend(event: FormEvent) {
    event.preventDefault(); setNotice("");
    try { await api.sendRequest(friendUsername.trim(), friendNote.trim()); setFriendUsername(""); setFriendNote(""); setNotice("好友申请已发送"); }
    catch (err) { setNotice(messageOf(err)); }
  }

  async function handleRequest(id: string, accept: boolean) {
    try { accept ? await api.acceptRequest(id) : await api.declineRequest(id); await refreshPeople(); }
    catch (err) { setNotice(messageOf(err)); }
  }

  return <main className="app-shell">
    <aside className="rail">
      <div className="logo">🐧</div>
      <button className="rail-button active" title="聊天">◫</button>
      <button className="rail-button" title="联系人" onClick={() => setShowPeople(true)}>♧</button>
      <div className="rail-spacer" />
      <button className="rail-button" title="退出登录" onClick={onLogout}>↪</button>
    </aside>
    <aside className="conversations">
      <div className="profile-card">
        <Avatar user={user} />
        <div><strong>{user.display_name}</strong><span>@{user.username}</span></div>
        <span className="online-dot" title="在线" />
      </div>
      <div className="search-row"><input aria-label="搜索联系人" value={search} onChange={(e) => setSearch(e.target.value)} placeholder="搜索联系人" /><button title="添加好友" onClick={() => setShowPeople(true)}>＋</button></div>
      <div className="list-heading"><span>聊天</span><small>{contacts.length} 位好友</small></div>
      <div className="contact-list">
        {filtered.length === 0 && <div className="empty-list"><span>🧊</span><p>还没有好友</p><button onClick={() => setShowPeople(true)}>添加第一位好友</button></div>}
        {filtered.map((contact) => <button key={contact.id} className={`contact-row ${selectedId === contact.id ? "selected" : ""}`} onClick={() => selectContact(contact)}>
          <div className={`presence-ring ${contact.presence}`}><Avatar user={contact} small /></div>
          <div className="contact-copy"><strong>{contact.display_name}</strong><span>{typing[contact.id] ? "正在输入…" : contact.signature || `@${contact.username}`}</span></div>
          {!!unread[contact.id] && <b className="badge">{unread[contact.id]}</b>}
        </button>)}
      </div>
    </aside>
    <section className="chat-panel">
      {notice && <button className="toast" onClick={() => setNotice("")}>{notice}</button>}
      {!selected ? <div className="welcome"><div className="welcome-penguin">🐧</div><h2>选择一位好友开始聊天</h2><p>消息会实时送达，也会安全保存为聊天记录。</p></div> : <>
        <header className="chat-header"><div><strong>{selected.display_name}</strong><span><i className={`status-dot ${selected.presence}`} />{selected.presence === "online" ? "在线" : selected.presence === "away" ? "离开" : "离线"}</span></div><button className="ghost" onClick={() => setShowPeople(true)}>好友申请 {requests.length ? `(${requests.length})` : ""}</button></header>
        <div className="message-list">
          {(messages[selected.id] ?? []).length === 0 && <div className="day-pill">还没有消息，打个招呼吧</div>}
          {(messages[selected.id] ?? []).map((message) => <div key={message.clientMsgId ?? message.id} className={`bubble-row ${message.sender_id === user.id ? "mine" : "theirs"}`}>
            {message.sender_id !== user.id && <Avatar user={selected} small />}
            <div><div className={`bubble ${message.failed ? "failed" : ""}`}>{message.body}</div><small>{new Date(message.created_at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}{message.sender_id === user.id && ` · ${message.failed ? "发送失败" : message.pending ? "发送中" : message.read_at ? "已读" : message.delivered_at ? "已送达" : "已发送"}`}</small></div>
          </div>)}
          {typing[selected.id] && <div className="typing-bubble"><span /><span /><span /></div>}
          <div ref={messageEndRef} />
        </div>
        <form className="composer" onSubmit={sendMessage}>
          <textarea aria-label="消息" value={compose} onChange={(e) => { setCompose(e.target.value); socketRef.current?.emit(e.target.value ? "typing:start" : "typing:stop", { toUserId: selected.id }); }} onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); e.currentTarget.form?.requestSubmit(); } }} placeholder="输入消息，按 Enter 发送" />
          <button className="send" disabled={!compose.trim()}>发送</button>
        </form>
      </>}
    </section>
    {showPeople && <div className="modal-backdrop" onMouseDown={() => setShowPeople(false)}><section className="people-modal" onMouseDown={(e) => e.stopPropagation()}>
      <header><div><p className="eyebrow">CONTACTS</p><h2>添加好友</h2></div><button className="close" onClick={() => setShowPeople(false)}>×</button></header>
      <form className="friend-form" onSubmit={addFriend}><label>对方企鹅号<input required value={friendUsername} onChange={(e) => setFriendUsername(e.target.value)} placeholder="输入用户名" /></label><label>验证消息<input value={friendNote} onChange={(e) => setFriendNote(e.target.value)} placeholder="你好，我是…" /></label><button className="primary">发送申请</button></form>
      <div className="request-list"><h3>收到的申请 <span>{requests.length}</span></h3>
        {requests.length === 0 && <p className="muted">暂时没有新的好友申请</p>}
        {requests.map((request) => <article key={request.id}><div className="request-avatar">🐧</div><div><strong>{request.from_display_name || request.from_username || `用户 ${request.from_user.slice(0, 8)}`}</strong><p>{request.message || "想加你为好友"}</p></div><button className="accept" onClick={() => handleRequest(request.id, true)}>接受</button><button className="decline" onClick={() => handleRequest(request.id, false)}>忽略</button></article>)}
      </div>
    </section></div>}
  </main>;
}
