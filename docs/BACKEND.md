# Backend VOICE

Документ описывает backend для iOS messenger VOICE на Supabase и LiveKit. Backend не содержит секретов. Конфиги проекта, anon key, LiveKit URL и ключи добавляются отдельно.

## Что добавлено

- Supabase SQL migrations:
  - `supabase/migrations/202609260001_voice_backend.sql`.
  - `supabase/migrations/202609260002_voice_backend_hardening.sql`.
- Edge Function LiveKit token: `supabase/functions/livekit-token`.
- DB security tests: `supabase/tests/voice_security.sql`.
- GitHub Actions backend security workflow: `.github/workflows/backend.yml`.
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
- Если указан `attachment_path`, он должен иметь формат `<conversation UUID>/<auth uid>/<random filename>` и принадлежать текущему conversation и пользователю.
- Для `voice` можно указать `duration_seconds`.

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

Идемпотентно создает direct conversation для пары пользователей и возвращает UUID conversation. Функция использует transaction advisory lock на отсортированную пару пользователей, поэтому одновременные вызовы для одной пары не создают дубль через этот RPC.

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

REST ответ является одним JSON object, не массивом:

```json
{
  "id": "<call uuid>",
  "conversation_id": "<conversation uuid>",
  "caller_id": "<caller uuid>",
  "callee_id": "<callee uuid>",
  "status": "ringing",
  "created_at": "2026-09-26T00:00:00Z",
  "ended_at": null
}
```

Защита:

- Caller должен быть участником conversation.
- Callee определяется сервером.
- Если caller или callee уже имеет активный `ringing` или `accepted` call, RPC возвращает ошибку.
- Сервер использует transaction advisory locks для пары пользователей.
- Старые `ringing` calls старше 60 секунд переводятся в `missed`.
- Старые `accepted` calls старше 2 часов переводятся в `ended`, чтобы не держать busy-state навсегда.

### `update_call_status(p_call_id uuid, p_status text) returns calls`

REST ответ является одним JSON object, не массивом, с теми же ключами, что `start_call`.

Разрешенные переходы:

- `ringing -> accepted`: только callee.
- `ringing -> declined`: только callee.
- `ringing -> ended`: caller или callee.
- `accepted -> ended`: caller или callee. App может вызывать это при sign out.
- `ringing -> missed`: caller или callee только после 60 секунд. App может вызывать это после 60 секунд ожидания. Сервер также переводит старые звонки в `missed` при RPC и token flow.

Запрещены произвольные изменения статуса и изменения чужих звонков.

## Storage contract

Buckets private.

### `media`

- Path: `<conversation UUID>/<auth uid>/<random filename>`.
- В filename не допускается `/`.
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

Signed URL authorization идет через private bucket и RLS `select` на `storage.objects`. Пользователь должен быть участником conversation.

### `avatars`

- Path: `<auth uid>/<random filename>`.
- В filename не допускается `/`.
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

Success response has exactly these JSON keys for parent iOS compatibility:

```json
{
  "token": "<livekit jwt>",
  "url": "<LIVEKIT_URL>"
}
```

Security:

- Function is deployed with `--no-verify-jwt`, but explicitly validates `Authorization: Bearer` by `supabase.auth.getUser()`.
- Expired Supabase access tokens are rejected with 401. iOS must refresh the Supabase session before requesting a LiveKit token.
- Function uses anon key and the user Bearer token for data reads, so RLS is active.
- Service role key is not used and is not returned.
- Actor must be `caller_id` or `callee_id`.
- Caller can get token while call is `ringing` or `accepted`.
- Callee can get token only after call is `accepted`.
- `ringing` call older than 60 seconds is rejected and cleanup RPC marks it as `missed`.
- `accepted` call older than 2 hours is rejected and cleanup marks it as `ended`.
- Room is deterministic inside the token grant: `voice-{call.id}`.
- Grant is only for this room, join, subscribe and publish audio source. TTL is 300 seconds.
- LiveKit server env only: `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`, `LIVEKIT_URL`.

CORS is optional for native iOS. If `ALLOWED_ORIGINS` is set, browser origins outside the comma-separated list are rejected.

### LiveKit revocation limitation

DB cannot call LiveKit APIs when a call becomes `ended`, `declined` or `missed`. This backend does not add a separate LiveKit cleanup endpoint because that would broaden the app contract. A token issued before status change can remain usable until its short TTL expires. Current bound is 300 seconds. Accepted calls also auto-end after 2 hours to prevent permanent busy state.

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
DB_URL="postgresql://postgres:postgres@127.0.0.1:54322/postgres"
psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/voice_security.sql
```

You can also run:

```bash
supabase test db
```

## CI security workflow

`.github/workflows/backend.yml` runs on backend path changes. It:

1. Installs Supabase CLI.
2. Installs `psql` client.
3. Starts Supabase local services.
4. Runs `supabase db reset`.
5. Executes `supabase/tests/voice_security.sql` through `psql` with `ON_ERROR_STOP=1`.

It uses only local demo credentials for the Supabase local database.

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
supabase db reset
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/voice_security.sql
```

Тесты проверяют:

- Создание профиля из auth trigger.
- Idempotent direct chat.
- Запрет sender spoof.
- Запрет attachment spoof.
- Запрет чтения чужих messages через RLS.
- Storage path checks для `media` и `avatars`.
- Call transitions, response shape и busy protection.
- `missed` после 60 секунд.

## Ограничения

- Push notifications не реализованы и не обещаны.
- E2EE не реализован и не заявлен.
- Unread counters отсутствуют по контракту.
- Group chats отсутствуют. `start_direct_chat` и calls рассчитаны на conversation с 2 участниками.
- LiveKit token ограничивает publish audio source в JWT grant. iOS также должен публиковать только audio track.
- LiveKit room не завершается через API при `ended`, `declined` или `missed`; токены ограничены TTL 300 секунд.
- Нет credentials в репозитории. Все секреты задаются через Supabase secrets.

## Отличия от fixed contract

- LiveKit success response возвращает только `{ "token": string, "url": string }` для совместимости с parent iOS client. Room и identity остаются внутри JWT и не возвращаются.
- Добавлен bounded timeout: `accepted` calls старше 2 часов переводятся в `ended`.
- Остальные table names, column names, RPC names, JSON keys и bucket path formats сохранены.
