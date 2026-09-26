-- Harden VOICE backend after independent security review.
-- Keeps the public contract stable while tightening helper exposure, storage paths,
-- message attachment ownership, stale calls and policy recursion safety.

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create or replace function private.is_uuid_text(value text)
returns boolean
language sql
immutable
as $$
select value ~*
'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
$$;

create or replace function private.is_media_path_for_user(p_path text,
p_conversation_id uuid, p_user_id uuid)
returns boolean
language sql
stable
as $$
select p_path ~*
'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[^/]+$'
and split_part(p_path, '/', 1) = p_conversation_id::text
and split_part(p_path, '/', 2) = p_user_id::text;
$$;

create or replace function private.is_media_path(p_path text,
p_conversation_id uuid)
returns boolean
language sql
stable
as $$
select p_path ~*
'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[^/]+$'
and split_part(p_path, '/', 1) = p_conversation_id::text;
$$;

create or replace function private.is_avatar_path_for_user(p_path text,
p_user_id uuid)
returns boolean
language sql
stable
as $$
select p_path ~*
'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[^/]+$'
and split_part(p_path, '/', 1) = p_user_id::text;
$$;

create or replace function private.is_conversation_member(p_conversation_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
select exists (
  select 1
  from public.conversation_members as cm
  where cm.conversation_id = p_conversation_id
    and cm.user_id = p_user_id
);
$$;

create or replace function private.is_participant_busy(p_user_id uuid, p_excluding_call_id uuid default null)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
select exists (
  select 1
  from public.calls as c
  where (c.caller_id = p_user_id or c.callee_id = p_user_id)
    and c.id is distinct from p_excluding_call_id
    and (
      (c.status = 'accepted' and c.created_at >= now() - interval '2 hours')
      or (c.status = 'ringing' and c.created_at >= now() - interval '60 seconds')
    )
);
$$;

create or replace function private.expire_stale_calls()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  affected integer;
  accepted_affected integer;
begin
  update public.calls as c
  set status = 'missed', ended_at = now()
  where c.status = 'ringing'
    and c.created_at < now() - interval '60 seconds';

  get diagnostics affected = row_count;

  update public.calls as c
  set status = 'ended', ended_at = now()
  where c.status = 'accepted'
    and c.created_at < now() - interval '2 hours';

  get diagnostics accepted_affected = row_count;
  return affected + accepted_affected;
end;
$$;

create or replace function public.expire_old_ringing_calls()
returns integer
language plpgsql
security definer
set search_path = public, private
as $$
begin
  return private.expire_stale_calls();
end;
$$;

create or replace function public.start_direct_chat(other_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, private
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
  if not exists (select 1 from public.profiles as p where p.id = other_user_id) then
    raise exception 'Peer profile not found' using errcode = 'P0002';
  end if;

  first_user := least(me, other_user_id);
  second_user := greatest(me, other_user_id);
  perform pg_advisory_xact_lock(hashtext(first_user::text), hashtext(second_user::text));

  select cm1.conversation_id
  into existing_id
  from public.conversation_members as cm1
  join public.conversation_members as cm2 on cm2.conversation_id = cm1.conversation_id
  where cm1.user_id = me
    and cm2.user_id = other_user_id
    and (
      select count(*)
      from public.conversation_members as cm3
      where cm3.conversation_id = cm1.conversation_id
    ) = 2
  order by cm1.conversation_id
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
set search_path = public, private
as $$
select private.expire_stale_calls() where auth.uid() is not null;

select
  c.id,
  peer.user_id as peer_id,
  p.username,
  p.display_name,
  p.avatar_path,
  lm.body as last_message,
  lm.kind as last_kind,
  lm.created_at as last_message_at
from public.conversations as c
join public.conversation_members as mine on mine.conversation_id = c.id and mine.user_id = auth.uid()
join public.conversation_members as peer on peer.conversation_id = c.id and peer.user_id <> auth.uid()
join public.profiles as p on p.id = peer.user_id
left join lateral (
  select m.body, m.kind, m.created_at
  from public.messages as m
  where m.conversation_id = c.id
  order by m.created_at desc
  limit 1
) as lm on true
order by lm.created_at desc nulls last, c.created_at desc;
$$;

create or replace function public.start_call(p_conversation_id uuid)
returns public.calls
language plpgsql
security definer
set search_path = public, private
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

  perform private.expire_stale_calls();

  select count(*), max(cm.user_id) filter (where cm.user_id <> me)
  into member_count, peer
  from public.conversation_members as cm
  where cm.conversation_id = p_conversation_id;

  if member_count <> 2 or peer is null or not private.is_conversation_member(p_conversation_id, me) then
    raise exception 'Direct conversation membership required' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtext(least(me, peer)::text), hashtext(greatest(me, peer)::text));

  if private.is_participant_busy(me) or private.is_participant_busy(peer) then
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
set search_path = public, private
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

  perform private.expire_stale_calls();

  select c.* into current_call
  from public.calls as c
  where c.id = p_call_id
  for update;

  if not found then
    raise exception 'Call not found' using errcode = 'P0002';
  end if;
  if me <> current_call.caller_id and me <> current_call.callee_id then
    raise exception 'Call actor required' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtext(least(current_call.caller_id, current_call.callee_id)::text), hashtext(greatest(current_call.caller_id, current_call.callee_id)::text));

  if p_status = 'missed' and current_call.status = 'missed' then
    return current_call;
  end if;

  if current_call.status = 'ringing' and current_call.created_at < now() - interval '60 seconds' then
    update public.calls as c set status = 'missed', ended_at = now()
    where c.id = p_call_id
    returning * into current_call;
    return current_call;
  end if;

  if current_call.status = 'accepted' and current_call.created_at < now() - interval '2 hours' then
    update public.calls as c set status = 'ended', ended_at = now()
    where c.id = p_call_id
    returning * into current_call;
    return current_call;
  end if;

  if p_status = 'accepted' then
    if me <> current_call.callee_id or current_call.status <> 'ringing' then
      raise exception 'Only the callee can accept a ringing call' using errcode = '42501';
    end if;
    if private.is_participant_busy(current_call.caller_id, p_call_id) or private.is_participant_busy(current_call.callee_id, p_call_id) then
      raise exception 'Participant already has an active call' using errcode = '55000';
    end if;
    update public.calls as c set status = 'accepted'
    where c.id = p_call_id
    returning * into current_call;
    return current_call;
  elsif p_status = 'declined' then
    if me <> current_call.callee_id or current_call.status <> 'ringing' then
      raise exception 'Only the callee can decline a ringing call' using errcode = '42501';
    end if;
    update public.calls as c set status = 'declined', ended_at = now()
    where c.id = p_call_id
    returning * into current_call;
    return current_call;
  elsif p_status = 'ended' then
    if current_call.status not in ('ringing', 'accepted') then
      raise exception 'Only active calls can be ended' using errcode = '22023';
    end if;
    update public.calls as c set status = 'ended', ended_at = now()
    where c.id = p_call_id
    returning * into current_call;
    return current_call;
  elsif p_status = 'missed' then
    if current_call.status <> 'ringing' or current_call.created_at >= now() - interval '60 seconds' then
      raise exception 'Only old ringing calls can be marked missed' using errcode = '22023';
    end if;
    update public.calls as c set status = 'missed', ended_at = now()
    where c.id = p_call_id
    returning * into current_call;
    return current_call;
  end if;

  raise exception 'Unsupported transition' using errcode = '22023';
end;
$$;

drop policy if exists "conversations member read" on public.conversations;
drop policy if exists "conversation members member read" on public.conversation_members;
drop policy if exists "messages member read" on public.messages;
drop policy if exists "messages member insert own sender" on public.messages;
drop policy if exists "calls member read" on public.calls;

create policy "conversations member read" on public.conversations
for select to authenticated using (private.is_conversation_member(id, auth.uid()));

create policy "conversation members member read" on public.conversation_members
for select to authenticated using (private.is_conversation_member(conversation_id, auth.uid()));

create policy "messages member read" on public.messages
for select to authenticated using (private.is_conversation_member(conversation_id, auth.uid()));

create policy "messages member insert own sender" on public.messages
for insert to authenticated
with check (
  sender_id = auth.uid()
  and private.is_conversation_member(conversation_id, auth.uid())
  and (attachment_path is null or private.is_media_path_for_user(attachment_path, conversation_id, auth.uid()))
);

create policy "calls member read" on public.calls
for select to authenticated using (private.is_conversation_member(conversation_id, auth.uid()));

drop policy if exists "media member read" on storage.objects;
drop policy if exists "media member upload own segment" on storage.objects;
drop policy if exists "media member update own segment" on storage.objects;
drop policy if exists "media member delete own segment" on storage.objects;
drop policy if exists "avatars authenticated read" on storage.objects;
drop policy if exists "avatars upload own segment" on storage.objects;
drop policy if exists "avatars update own segment" on storage.objects;
drop policy if exists "avatars delete own segment" on storage.objects;

create policy "media member read" on storage.objects
for select to authenticated
using (
  bucket_id = 'media'
  and private.is_media_path(name, split_part(name, '/', 1)::uuid)
  and private.is_conversation_member(split_part(name, '/', 1)::uuid, auth.uid())
);

create policy "media member upload own segment" on storage.objects
for insert to authenticated
with check (
  bucket_id = 'media'
  and private.is_media_path_for_user(name, split_part(name, '/', 1)::uuid, auth.uid())
  and private.is_conversation_member(split_part(name, '/', 1)::uuid, auth.uid())
);

create policy "media member update own segment" on storage.objects
for update to authenticated
using (
  bucket_id = 'media'
  and private.is_media_path_for_user(name, split_part(name, '/', 1)::uuid, auth.uid())
  and private.is_conversation_member(split_part(name, '/', 1)::uuid, auth.uid())
)
with check (
  bucket_id = 'media'
  and private.is_media_path_for_user(name, split_part(name, '/', 1)::uuid, auth.uid())
  and private.is_conversation_member(split_part(name, '/', 1)::uuid, auth.uid())
);

create policy "media member delete own segment" on storage.objects
for delete to authenticated
using (
  bucket_id = 'media'
  and private.is_media_path_for_user(name, split_part(name, '/', 1)::uuid, auth.uid())
  and private.is_conversation_member(split_part(name, '/', 1)::uuid, auth.uid())
);

create policy "avatars authenticated read" on storage.objects
for select to authenticated using (
  bucket_id = 'avatars'
  and private.is_avatar_path_for_user(name, split_part(name, '/', 1)::uuid)
);

create policy "avatars upload own segment" on storage.objects
for insert to authenticated with check (
  bucket_id = 'avatars'
  and private.is_avatar_path_for_user(name, auth.uid())
);

create policy "avatars update own segment" on storage.objects
for update to authenticated
using (
  bucket_id = 'avatars'
  and private.is_avatar_path_for_user(name, auth.uid())
)
with check (
  bucket_id = 'avatars'
  and private.is_avatar_path_for_user(name, auth.uid())
);

create policy "avatars delete own segment" on storage.objects
for delete to authenticated using (
  bucket_id = 'avatars'
  and private.is_avatar_path_for_user(name, auth.uid())
);

revoke all on function public.is_conversation_member(uuid, uuid) from public, anon, authenticated;
revoke all on function public.is_call_actor(uuid, uuid) from public, anon, authenticated;
revoke all on function public.is_participant_busy(uuid, uuid) from public, anon, authenticated;
revoke all on function public.start_direct_chat(uuid) from public, anon;
revoke all on function public.conversation_list() from public, anon;
revoke all on function public.start_call(uuid) from public, anon;
revoke all on function public.update_call_status(uuid, text) from public, anon;
revoke all on function public.expire_old_ringing_calls() from public, anon;
revoke all on all functions in schema private from public, anon, authenticated;

grant usage on schema private to authenticated;
grant execute on function public.start_direct_chat(uuid) to authenticated;
grant execute on function public.conversation_list() to authenticated;
grant execute on function public.start_call(uuid) to authenticated;
grant execute on function public.update_call_status(uuid, text) to authenticated;
grant execute on function public.expire_old_ringing_calls() to authenticated;
grant execute on function private.is_conversation_member(uuid, uuid) to authenticated;
grant execute on function private.is_media_path(text, uuid) to authenticated;
grant execute on function private.is_media_path_for_user(text, uuid, uuid) to authenticated;
grant execute on function private.is_avatar_path_for_user(text, uuid) to authenticated;
