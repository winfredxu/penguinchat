# PenguinChat

PenguinChat is a local-first QQ-style chat MVP with registration/login, friend
requests, presence, persistent message history, typing indicators, delivery/read
receipts, and real-time one-to-one messaging.

## Local deployment

Requirements: Docker Desktop (or Docker Engine with Compose).

```bash
docker compose up --build -d
```

Open <http://localhost:5173>. The API health endpoint is available at
<http://localhost:3100/health>. Override either host port with
`PENGUINCHAT_APP_PORT` or `PENGUINCHAT_API_PORT` if needed.

To verify chat, open the app in two separate browser profiles, register two users,
send and accept a friend request, then select the new contact and send messages.

```bash
docker compose logs -f api app
docker compose down
```

PostgreSQL data is kept in the `pgdata` volume. `docker compose down` stops the
deployment without deleting accounts or messages.

## Development

Run the database, Redis, and API from the repository root, then run the client:

```bash
docker compose up -d postgres redis api
cd client
npm install
npm run dev
```

Verification:

```bash
npm test
npm run build
cd client && npm test && npm run build
```

With the full Docker stack running, execute the repeatable dual-user smoke test:

```bash
cd client && node e2e.local.mjs
```
