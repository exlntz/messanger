# Backend VOICE

Документ описывает стартовый backend для iOS messenger VOICE на Supabase и LiveKit. Backend не содержит секретов. Конфиги проекта, anon key, LiveKit URL и ключи добавляются отдельно.

## Что добавлено

- Supabase SQL migration: `supabase/migrations/202609260001_voice_backend.sql`.
- Edge Function LiveKit token: `supabase/functions/livekit-token`.
- DB security tests: `supabase/tests/voice_security.sql`.
- Supabase local config: `supabase/config.toml`.

## Схема данных

### `profiles`

```sql
profiles(
  id uuid primary key references auth.users(id),
  username text unique not null,
  display_name text not null,
  avatar_path text null
)
```

Профиль создается trigger на `auth.users`. Trigger берет `raw_user_meta_data.username` и `raw_user_meta_data.display_name`, приводит username к нижнему регистру, удаляет опасные символы и проверяет формат `^[a-z0-9_]{3,32}$`. Если username невалидный или занят, сервер создает безопасный `user_<random>`.

Клиент может делать PATCH только своего профиля. Username должен быть lowercase и валидным.

### `conversations`

```sql
conversations(
  id uuid primary key,
  created_at timestamptz not null
)
```

### `conversation_members`

```sql
conversation_members(
  conversation_id uuid references conversations(id),
  user_id uuid references profiles(id),
  primary key (conversation_id, user_id)
)
```

### `messages`

```sql
messages(
  id uuid primary key,
  conversation_id uuid references conversations(id),
  sender_id uuid references profiles(id),
  kind text check (kind in ('text', 'image', 'voice')),
  body text null,
  attachment_path text null,
  duration_seconds double precision null,
  created_at timestamptz not null
)
```

Сообщение создается прямым `insert` через REST с `return=representation`. RLS требует:

- `sender_id = auth.uid()`.
- Пользователь состоит в `conversation_id`.
- Для `text` нельзя указать `attachment_path`.
- Для `image` и `voice` можно указать `attachment_path`.
- `duration_seconds` разрешен только для `voice`.

### `calls`

```sql
calls(
  id uuid primary key,
  conversation_id uuid references conversations(id),
  caller_id uuid references profiles(id),
  callee_id uuid references profiles(id),
  status text check (status in ('ringing', 'accepted', 'ended', 'declined', 'missed')),
  created_at timestamptz not null,
  ended_at timestamptz null
)
```

Звонки видят только участники conversation. Прямых insert/update для клиента нет. Используйте RPC.

## RPC contract

Все JSON keys используют `snake_case`.

### `start_direct_chat(other_user_id uuid) returns uuid`

Идемпотентно создает direct conversation для пары пользователей и возвращает UUID conversation.

REST пример:

```http
POST /rest/v1/rpc/start_direct_chat
Authorization: Bearer <user access token>
Content-Type: application/json

{ "other_user_id": "<peer uuid>" }
```

Ответ является JSON scalar:

```json
"<conversation uuid>"
```

### `conversation_list()`

Возвращает массив:

```json
[
  {
    "id": "<conversation uuid>",
    "peer_id": "<peer uuid>",
    "username": "peer_username",
    "display_name": "Peer Name",
    "avatar_path": null,
    "last_message": "hello",
    "last_kind": "text",
    "last_message_at": "2026-09-26T00:00:00Z"
  }
]
```

`last_message`, `last_kind`, `last_message_at` могут быть `null`. Unread feature отсутствует.

### `start_call(p_conversation_id uuid) returns calls`

Создает звонок со статусом `ringing`. RPC работает только для direct conversation с 2 участниками.

Защита:

- Caller должен быть участником conversation.
- Callee определяется сервером.
- Если caller или callee уже имеет `ringing` или `accepted` call, RPC возвращает ошибку.
- Сервер использует transaction advisory locks для пары пользователей.
- Старые `ringing` calls старше 60 секунд переводятся в `missed`.

### `update_call_status(p_call_id uuid, p_status text) returns calls`

Разрешенные переходы:

- `ringing -> accepted`: только callee.
- `ringing -> declined`: только callee.
- `ringing -> ended`: caller или callee.
- `accepted -> ended`: caller или callee.
- `ringing -> missed`: caller или callee только после 60 секунд. Также сервер сам переводит старые звонки в `missed` при RPC и token flow.

Запрещены произвольные изменения статуса и изменения чужих звонков.

## Storage contract

Buckets private.

### `media`

- Path: `<conversation UUID>/<auth uid>/<random filename>`.
- Limit: 15 MB.
- MIME: `image/jpeg`, `image/png`, `image/webp`, `audio/mpeg`, `audio/mp4`, `audio/aac`, `audio/wav`, `audio/x-m4a`, `audio/m4a`.
- Read: authenticated member of conversation.
- Write/update/delete: authenticated member and second path segment must equal `auth.uid()`.

Upload через REST Storage:

```http
POST /storage/v1/object/media/<conversation uuid>/<auth uid>/<random filename>
Authorization: Bearer <user access token>
Content-Type: <mime>
```

Signed URL:

```http
POST /storage/v1/object/sign/media/<conversation uuid>/<auth uid>/<random filename>
Authorization: Bearer <user access token>
Content-Type: application/json

{ "expiresIn": 300 }
```

### `avatars`

- Path: `<auth uid>/<random filename>`.
- Limit: 5 MB.
- MIME: `image/jpeg`, `image/png`, `image/webp`.
- Read: any authenticated user.
- Write/update/delete: only own first path segment.

## Realtime

Publication `supabase_realtime` includes:

- `public.messages`
- `public.calls`

RLS still applies. Subscribe with authenticated Supabase client. A user receives only rows that their JWT can select.

## LiveKit token Edge Function

Function name: `livekit-token`.

Request:

```http
POST /functions/v1/livekit-token
Authorization: Bearer <Supabase access token>
Content-Type: application/json

{ "call_id": "<call uuid>" }
```

Response:

```json
{
  "token": "<livekit jwt>",
  "url": "<LIVEKIT_URL>",
  "room": "voice-<call uuid>",
  "identity": "<auth uid>",
  "expires_in": 300
}
```

Security:

- Function is deployed with `--no-verify-jwt`, but explicitly validates `Authorization: Bearer` by `supabase.auth.getUser()`.
- Function uses anon key and the user Bearer token for data reads, so RLS is active.
- Service role key is not used and is not returned.
- Actor must be `caller_id` or `callee_id`.
- Caller can get token while call is `ringing` or `accepted`.
- Callee can get token only after call is `accepted`.
- `ringing` call older than 60 seconds is rejected and cleanup RPC marks it as `missed`.
- Room is deterministic: `voice-{call.id}`.
- Grant is only for this room, join, subscribe and publish audio source. TTL is 300 seconds.
- LiveKit server env only: `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`, `LIVEKIT_URL`.

CORS is optional for native iOS. If `ALLOWED_ORIGINS` is set, browser origins outside the comma-separated list are rejected.

## Auth и регистрация

Supabase email confirmation включен в `supabase/config.toml`.

Flow для iOS:

1. App calls Supabase sign up with email/password and optional metadata:

```json
{
  "username": "alice",
  "display_name": "Alice"
}
```

2. User confirms email from email link.
3. App shows login screen. Deep link after confirmation is not required.
4. App signs in after confirmation and receives session.
5. Profile already exists because DB trigger created it on `auth.users` insert.

## Local setup

```bash
supabase start
supabase db reset
supabase test db
```

## Deploy setup

```bash
supabase link --project-ref <project-ref>
supabase db push
supabase secrets set \
  LIVEKIT_API_KEY=<key> \
  LIVEKIT_API_SECRET=<secret> \
  LIVEKIT_URL=<wss-or-https-livekit-url> \
  ALLOWED_ORIGINS=
supabase functions deploy livekit-token --no-verify-jwt
```

После deploy добавьте iOS app config:

- Supabase URL.
- Supabase anon publishable key.
- LiveKit URL из function response.

Не добавляйте service role key в приложение.

## Security tests

```bash
supabase test db
```

Тесты проверяют:

- Создание профиля из auth trigger.
- Idempotent direct chat.
- Запрет sender spoof.
- Запрет чтения чужих messages через RLS.
- Storage path checks для `media`.
- Call transitions и busy protection.

## Ограничения

- Push notifications не реализованы и не обещаны.
- E2EE не реализован и не заявлен.
- Unread counters отсутствуют по контракту.
- Group chats отсутствуют. `start_direct_chat` и calls рассчитаны на conversation с 2 участниками.
- LiveKit token ограничивает publish audio source в JWT grant. iOS также должен публиковать только audio track.
- Нет credentials в репозитории. Все секреты задаются через Supabase secrets.

## Отличия от fixed contract

Отличий нет. Backend сохраняет указанные table names, column names, RPC names, JSON keys, bucket path formats и LiveKit token flow.
