-- VOICE messenger backend: auth profiles, direct chats, messages, calls, storage and realtime.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique,
  display_name text not null,
  avatar_path text
);

create table if not exists public.conversations (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now()
);

create table if not exists public.conversation_members (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  primary key (conversation_id, user_id)
);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('text', 'image', 'voice')),
  body text,
  attachment_path text,
  duration_seconds double precision,
  created_at timestamptz not null default now(),
  check (body is not null or attachment_path is not null),
  check (kind <> 'text' or attachment_path is null),
  check (kind = 'voice' or duration_seconds is null),
  check (duration_seconds is null or duration_seconds >= 0)
);

create table if not exists public.calls (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  caller_id uuid not null references public.profiles(id) on delete cascade,
  callee_id uuid not null references public.profiles(id) on delete cascade,
  status text not null check (status in ('ringing', 'accepted', 'ended', 'declined', 'missed')),
  created_at timestamptz not null default now(),
  ended_at timestamptz,
  check (caller_id <> callee_id),
  check ((status in ('ended', 'declined', 'missed') and ended_at is not null) or (status in ('ringing', 'accepted') and ended_at is null))
);

create index if not exists conversation_members_user_idx on public.conversation_members(user_id, conversation_id);
create index if not exists messages_conversation_created_idx on public.messages(conversation_id, created_at desc);
create index if not exists calls_participants_status_idx on public.calls(caller_id, callee_id, status, created_at desc);
create index if not exists calls_conversation_created_idx on public.calls(conversation_id, created_at desc);

create or replace function public.is_uuid_text(value text)
returns boolean
language sql
immutable
as $$
  select value ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
$$;

create or replace function public.is_conversation_member(p_conversation_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.conversation_members cm
    where cm.conversation_id = p_conversation_id
      and cm.user_id = p_user_id
  );
$$;

create or replace function public.is_call_actor(p_call_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.calls c
    where c.id = p_call_id
      and (c.caller_id = p_user_id or c.callee_id = p_user_id)
  );
$$;

create or replace function public.validate_profile_username(value text)
returns boolean
language sql
immutable
as $$
  select value ~ '^[a-z0-9_]{3,32}$';
$$;

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  raw_username text;
  candidate text;
  safe_display text;
begin
  raw_username := lower(trim(coalesce(new.raw_user_meta_data ->> 'username', split_part(new.email, '@', 1), '')));
  candidate := regexp_replace(raw_username, '[^a-z0-9_]+', '_', 'g');
  candidate := trim(both '_' from left(candidate, 32));

  if not public.validate_profile_username(candidate) then
    candidate := 'user_' || substr(replace(new.id::text, '-', ''), 1, 12);
  end if;

  safe_display := nullif(trim(coalesce(new.raw_user_meta_data ->> 'display_name', new.raw_user_meta_data ->> 'username', split_part(new.email, '@', 1), '')), '');
  safe_display := left(coalesce(safe_display, candidate), 80);

  loop
    begin
      insert into public.profiles(id, username, display_name)
      values (new.id, candidate, safe_display);
      exit;
    exception when unique_violation then
      candidate := 'user_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 12);
    end;
  end loop;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_auth_user();

create or replace function public.expire_old_ringing_calls()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  affected integer;
begin
  update public.calls
  set status = 'missed', ended_at = now()
  where status = 'ringing'
    and created_at < now() - interval '60 seconds';

  get diagnostics affected = row_count;
  return affected;
end;
$$;

create or replace function public.is_participant_busy(p_user_id uuid, p_excluding_call_id uuid default null)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.calls c
    where (c.caller_id = p_user_id or c.callee_id = p_user_id)
      and c.id is distinct from p_excluding_call_id
      and (
        c.status = 'accepted'
        or (c.status = 'ringing' and c.created_at >= now() - interval '60 seconds')
      )
  );
$$;

create or replace function public.start_direct_chat(other_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  existing_id uuid;
  new_id uuid;
  first_user uuid;
  second_user uuid;
begin
  if me is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  if other_user_id is null or other_user_id = me then
    raise exception 'Invalid peer' using errcode = '22023';
  end if;
  if not exists (select 1 from public.profiles where id = other_user_id) then
    raise exception 'Peer profile not found' using errcode = 'P0002';
  end if;

  first_user := least(me, other_user_id);
  second_user := greatest(me, other_user_id);
  perform pg_advisory_xact_lock(hashtext(first_user::text), hashtext(second_user::text));

  select cm1.conversation_id
  into existing_id
  from public.conversation_members cm1
  join public.conversation_members cm2 on cm2.conversation_id = cm1.conversation_id
  where cm1.user_id = me
    and cm2.user_id = other_user_id
    and (select count(*) from public.conversation_members cm3 where cm3.conversation_id = cm1.conversation_id) = 2
  limit 1;

  if existing_id is not null then
    return existing_id;
  end if;

  insert into public.conversations default values returning id into new_id;
  insert into public.conversation_members(conversation_id, user_id)
  values (new_id, me), (new_id, other_user_id);
  return new_id;
end;
$$;

create or replace function public.conversation_list()
returns table (
  id uuid,
  peer_id uuid,
  username text,
  display_name text,
  avatar_path text,
  last_message text,
  last_kind text,
  last_message_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select public.expire_old_ringing_calls() where auth.uid() is not null;

  select
    c.id,
    peer.user_id as peer_id,
    p.username,
    p.display_name,
    p.avatar_path,
    lm.body as last_message,
    lm.kind as last_kind,
    lm.created_at as last_message_at
  from public.conversations c
  join public.conversation_members mine on mine.conversation_id = c.id and mine.user_id = auth.uid()
  join public.conversation_members peer on peer.conversation_id = c.id and peer.user_id <> auth.uid()
  join public.profiles p on p.id = peer.user_id
  left join lateral (
    select m.body, m.kind, m.created_at
    from public.messages m
    where m.conversation_id = c.id
    order by m.created_at desc
    limit 1
  ) lm on true
  order by lm.created_at desc nulls last, c.created_at desc;
$$;

create or replace function public.start_call(p_conversation_id uuid)
returns public.calls
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  peer uuid;
  member_count integer;
  created_call public.calls;
begin
  if me is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;

  perform public.expire_old_ringing_calls();

  select count(*), max(user_id) filter (where user_id <> me)
  into member_count, peer
  from public.conversation_members
  where conversation_id = p_conversation_id;

  if member_count <> 2 or peer is null or not public.is_conversation_member(p_conversation_id, me) then
    raise exception 'Direct conversation membership required' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtext(least(me, peer)::text), hashtext(greatest(me, peer)::text));

  if public.is_participant_busy(me) or public.is_participant_busy(peer) then
    raise exception 'Participant already has an active call' using errcode = '55000';
  end if;

  insert into public.calls(conversation_id, caller_id, callee_id, status)
  values (p_conversation_id, me, peer, 'ringing')
  returning * into created_call;

  return created_call;
end;
$$;

create or replace function public.update_call_status(p_call_id uuid, p_status text)
returns public.calls
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  current_call public.calls;
begin
  if me is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  if p_status not in ('accepted', 'ended', 'declined', 'missed') then
    raise exception 'Invalid call status' using errcode = '22023';
  end if;

  perform public.expire_old_ringing_calls();

  select * into current_call
  from public.calls
  where id = p_call_id
  for update;

  if not found then
    raise exception 'Call not found' using errcode = 'P0002';
  end if;
  if me <> current_call.caller_id and me <> current_call.callee_id then
    raise exception 'Call actor required' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtext(least(current_call.caller_id, current_call.callee_id)::text), hashtext(greatest(current_call.caller_id, current_call.callee_id)::text));

  if current_call.status = 'ringing' and current_call.created_at < now() - interval '60 seconds' then
    update public.calls set status = 'missed', ended_at = now()
    where id = p_call_id
    returning * into current_call;
    return current_call;
  end if;

  if p_status = 'accepted' then
    if me <> current_call.callee_id or current_call.status <> 'ringing' then
      raise exception 'Only the callee can accept a ringing call' using errcode = '42501';
    end if;
    if public.is_participant_busy(current_call.caller_id, p_call_id) or public.is_participant_busy(current_call.callee_id, p_call_id) then
      raise exception 'Participant already has an active call' using errcode = '55000';
    end if;
    update public.calls set status = 'accepted'
    where id = p_call_id
    returning * into current_call;
    return current_call;
  elsif p_status = 'declined' then
    if me <> current_call.callee_id or current_call.status <> 'ringing' then
      raise exception 'Only the callee can decline a ringing call' using errcode = '42501';
    end if;
    update public.calls set status = 'declined', ended_at = now()
    where id = p_call_id
    returning * into current_call;
    return current_call;
  elsif p_status = 'ended' then
    if current_call.status not in ('ringing', 'accepted') then
      raise exception 'Only active calls can be ended' using errcode = '22023';
    end if;
    update public.calls set status = 'ended', ended_at = now()
    where id = p_call_id
    returning * into current_call;
    return current_call;
  elsif p_status = 'missed' then
    if current_call.status <> 'ringing' or current_call.created_at >= now() - interval '60 seconds' then
      raise exception 'Only old ringing calls can be marked missed' using errcode = '22023';
    end if;
    update public.calls set status = 'missed', ended_at = now()
    where id = p_call_id
    returning * into current_call;
    return current_call;
  end if;

  raise exception 'Unsupported transition' using errcode = '22023';
end;
$$;

alter table public.profiles enable row level security;
alter table public.conversations enable row level security;
alter table public.conversation_members enable row level security;
alter table public.messages enable row level security;
alter table public.calls enable row level security;

create policy "profiles authenticated read" on public.profiles
  for select to authenticated using (true);
create policy "profiles own update" on public.profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid() and public.validate_profile_username(username) and username = lower(username));

create policy "conversations member read" on public.conversations
  for select to authenticated using (public.is_conversation_member(id, auth.uid()));

create policy "conversation members member read" on public.conversation_members
  for select to authenticated using (public.is_conversation_member(conversation_id, auth.uid()));

create policy "messages member read" on public.messages
  for select to authenticated using (public.is_conversation_member(conversation_id, auth.uid()));
create policy "messages member insert own sender" on public.messages
  for insert to authenticated
  with check (sender_id = auth.uid() and public.is_conversation_member(conversation_id, auth.uid()));

create policy "calls member read" on public.calls
  for select to authenticated using (public.is_conversation_member(conversation_id, auth.uid()));

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values
  ('media', 'media', false, 15728640, array['image/jpeg', 'image/png', 'image/webp', 'audio/mpeg', 'audio/mp4', 'audio/aac', 'audio/wav', 'audio/x-m4a', 'audio/m4a']),
  ('avatars', 'avatars', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

create policy "media member read" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'media'
    and public.is_uuid_text(split_part(name, '/', 1))
    and public.is_conversation_member(split_part(name, '/', 1)::uuid, auth.uid())
  );
create policy "media member upload own segment" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'media'
    and public.is_uuid_text(split_part(name, '/', 1))
    and split_part(name, '/', 2) = auth.uid()::text
    and public.is_conversation_member(split_part(name, '/', 1)::uuid, auth.uid())
  );
create policy "media member update own segment" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'media'
    and public.is_uuid_text(split_part(name, '/', 1))
    and split_part(name, '/', 2) = auth.uid()::text
    and public.is_conversation_member(split_part(name, '/', 1)::uuid, auth.uid())
  )
  with check (
    bucket_id = 'media'
    and public.is_uuid_text(split_part(name, '/', 1))
    and split_part(name, '/', 2) = auth.uid()::text
    and public.is_conversation_member(split_part(name, '/', 1)::uuid, auth.uid())
  );
create policy "media member delete own segment" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'media'
    and public.is_uuid_text(split_part(name, '/', 1))
    and split_part(name, '/', 2) = auth.uid()::text
    and public.is_conversation_member(split_part(name, '/', 1)::uuid, auth.uid())
  );

create policy "avatars authenticated read" on storage.objects
  for select to authenticated using (bucket_id = 'avatars');
create policy "avatars upload own segment" on storage.objects
  for insert to authenticated with check (bucket_id = 'avatars' and split_part(name, '/', 1) = auth.uid()::text);
create policy "avatars update own segment" on storage.objects
  for update to authenticated
  using (bucket_id = 'avatars' and split_part(name, '/', 1) = auth.uid()::text)
  with check (bucket_id = 'avatars' and split_part(name, '/', 1) = auth.uid()::text);
create policy "avatars delete own segment" on storage.objects
  for delete to authenticated using (bucket_id = 'avatars' and split_part(name, '/', 1) = auth.uid()::text);

alter publication supabase_realtime add table public.messages;
alter publication supabase_realtime add table public.calls;

revoke all on all tables in schema public from anon;
grant usage on schema public to authenticated;
grant select, update on public.profiles to authenticated;
grant select on public.conversations, public.conversation_members, public.calls to authenticated;
grant select, insert on public.messages to authenticated;
grant execute on function public.start_direct_chat(uuid) to authenticated;
grant execute on function public.conversation_list() to authenticated;
grant execute on function public.start_call(uuid) to authenticated;
grant execute on function public.update_call_status(uuid, text) to authenticated;
grant execute on function public.expire_old_ringing_calls() to authenticated;
