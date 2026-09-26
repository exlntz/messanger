begin;

create extension if not exists pgcrypto;

create or replace function pg_temp.assert_true(condition boolean, message text)
returns void
language plpgsql
as $$
begin
  if condition is distinct from true then
    raise exception '%', message;
  end if;
end;
$$;

create or replace function pg_temp.assert_eq(actual text, expected text, message text)
returns void
language plpgsql
as $$
begin
  if actual is distinct from expected then
    raise exception '% (expected %, got %)', message, expected, actual;
  end if;
end;
$$;

create or replace function pg_temp.assert_raises(sql_text text, expected_state text, message text)
returns void
language plpgsql
as $$
declare
  actual_state text;
begin
  begin
    execute sql_text;
  exception when others then
    get stacked diagnostics actual_state = returned_sqlstate;
    if actual_state = expected_state then
      return;
    end if;
    raise exception '% (expected SQLSTATE %, got %)', message, expected_state, actual_state;
  end;

  raise exception '% (expected SQLSTATE %, but statement succeeded)', message, expected_state;
end;
$$;

insert into auth.users(id, email, encrypted_password, email_confirmed_at, raw_user_meta_data)
values
  ('00000000-0000-0000-0000-0000000000a1', 'alice@example.test', 'x', now(), '{"username":"Alice","display_name":"Alice"}'::jsonb),
  ('00000000-0000-0000-0000-0000000000b2', 'bob@example.test', 'x', now(), '{"username":"bob","display_name":"Bob"}'::jsonb),
  ('00000000-0000-0000-0000-0000000000c3', 'carol@example.test', 'x', now(), '{"username":"carol","display_name":"Carol"}'::jsonb)
on conflict (id) do nothing;

select pg_temp.assert_true(
  exists (
    select 1
    from public.profiles
    where id = '00000000-0000-0000-0000-0000000000a1'
      and username = 'alice'
  ),
  'auth trigger creates lowercase profile'
);

set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select public.start_direct_chat('00000000-0000-0000-0000-0000000000b2');
select pg_temp.assert_true(
  public.start_direct_chat('00000000-0000-0000-0000-0000000000b2') = public.start_direct_chat('00000000-0000-0000-0000-0000000000b2'),
  'start_direct_chat is idempotent for repeated calls'
);

create temp table test_ids as
select public.start_direct_chat('00000000-0000-0000-0000-0000000000b2') as ab_conversation_id;

select pg_temp.assert_eq(
  (select count(*)::text from public.conversation_members),
  '2',
  'idempotent chat has exactly two membership rows'
);
select pg_temp.assert_true(
  (select ab_conversation_id is not null from test_ids),
  'start_direct_chat returns uuid scalar'
);

insert into public.messages(conversation_id, sender_id, kind, body)
select ab_conversation_id, '00000000-0000-0000-0000-0000000000a1', 'text', 'hello'
from test_ids;

select pg_temp.assert_raises($sql$
  insert into public.messages(conversation_id, sender_id, kind, body)
  select ab_conversation_id, '00000000-0000-0000-0000-0000000000b2', 'text', 'spoof'
  from test_ids
$sql$, '42501', 'sender spoof is rejected');

select pg_temp.assert_raises($sql$
  insert into public.messages(conversation_id, sender_id, kind, attachment_path)
  select ab_conversation_id, '00000000-0000-0000-0000-0000000000a1', 'image',
    ab_conversation_id::text || '/00000000-0000-0000-0000-0000000000b2/file.jpg'
  from test_ids
$sql$, '42501', 'message cannot reference peer-owned media path');

insert into public.messages(conversation_id, sender_id, kind, attachment_path)
select ab_conversation_id, '00000000-0000-0000-0000-0000000000a1', 'image',
  ab_conversation_id::text || '/00000000-0000-0000-0000-0000000000a1/file.jpg'
from test_ids;

select pg_temp.assert_eq(
  (select count(*)::text from public.conversation_list()),
  '1',
  'conversation_list returns member conversation'
);
select pg_temp.assert_true(
  (select to_jsonb(cl) ? 'peer_id' from public.conversation_list() as cl limit 1),
  'conversation_list row has peer_id key'
);

select pg_temp.assert_raises($sql$
  update public.profiles
  set username = 'Bad Name'
  where id = '00000000-0000-0000-0000-0000000000a1'
$sql$, '42501', 'invalid profile username update is rejected');

insert into storage.objects(bucket_id, name, owner, metadata)
select 'media', ab_conversation_id::text || '/00000000-0000-0000-0000-0000000000a1/file.jpg', '00000000-0000-0000-0000-0000000000a1', '{}'::jsonb
from test_ids;

select pg_temp.assert_raises($sql$
  insert into storage.objects(bucket_id, name, owner, metadata)
  select 'media', ab_conversation_id::text || '/00000000-0000-0000-0000-0000000000a1/nested/file.jpg', '00000000-0000-0000-0000-0000000000a1', '{}'::jsonb
  from test_ids
$sql$, '42501', 'media paths reject nested filenames');

select pg_temp.assert_raises($sql$
  insert into storage.objects(bucket_id, name, owner, metadata)
  select 'media', ab_conversation_id::text || '/00000000-0000-0000-0000-0000000000b2/file.jpg', '00000000-0000-0000-0000-0000000000a1', '{}'::jsonb
  from test_ids
$sql$, '42501', 'member cannot upload media under peer uid segment');

reset role;
insert into storage.objects(bucket_id, name, owner, metadata)
select 'media', ab_conversation_id::text || '/00000000-0000-0000-0000-0000000000b2/file.jpg', '00000000-0000-0000-0000-0000000000b2', '{}'::jsonb
from test_ids;

set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select pg_temp.assert_eq(
  (
    select count(*)::text
    from storage.objects
    where bucket_id = 'media'
      and name like (select ab_conversation_id::text || '/%' from test_ids)
  ),
  '2',
  'conversation member can read peer media in same conversation'
);

insert into storage.objects(bucket_id, name, owner, metadata)
values ('avatars', '00000000-0000-0000-0000-0000000000a1/avatar.jpg', '00000000-0000-0000-0000-0000000000a1', '{}'::jsonb);

select pg_temp.assert_raises($sql$
  insert into storage.objects(bucket_id, name, owner, metadata)
  values ('avatars', '00000000-0000-0000-0000-0000000000b2/avatar.jpg', '00000000-0000-0000-0000-0000000000a1', '{}'::jsonb)
$sql$, '42501', 'user cannot upload avatar under peer uid segment');

select pg_temp.assert_true(
  not has_schema_privilege(current_user, 'private', 'USAGE'),
  'authenticated cannot use private schema directly'
);
select pg_temp.assert_true(
  not has_function_privilege(current_user, 'public.is_conversation_member(uuid, uuid)', 'EXECUTE'),
  'legacy membership helper is not callable through exposed contract'
);
select pg_temp.assert_raises(
  $$select private.is_conversation_member('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1')$$,
  '42501',
  'direct private helper call is rejected'
);

select public.start_call((select ab_conversation_id from test_ids));

select pg_temp.assert_raises($sql$
  select public.start_call(ab_conversation_id)
  from test_ids
$sql$, '55000', 'busy caller cannot start another call');

create temp table call_ids as
select * from public.calls order by created_at desc limit 1;

select pg_temp.assert_true(
  (select to_jsonb(c) ? 'conversation_id' from call_ids as c limit 1),
  'start_call returns a calls JSON object shape'
);

select pg_temp.assert_raises($sql$
  select public.update_call_status((select id from call_ids), 'accepted')
$sql$, '42501', 'caller cannot accept own ringing call');

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b2', true);

create temp table accepted_call as
select * from public.update_call_status((select id from call_ids), 'accepted');

select pg_temp.assert_eq(
  (select status from accepted_call limit 1),
  'accepted',
  'callee can accept ringing call'
);
select pg_temp.assert_true(
  (select to_jsonb(c) ? 'id' and to_jsonb(c) ? 'status' from accepted_call as c limit 1),
  'update_call_status returns a calls JSON object shape'
);

select public.update_call_status((select id from call_ids), 'ended');

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
create temp table old_call as
select * from public.start_call((select ab_conversation_id from test_ids));

reset role;
update public.calls
set created_at = now() - interval '61 seconds'
where id = (select id from old_call);

set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select pg_temp.assert_eq(
  (select status from public.update_call_status((select id from old_call), 'missed')),
  'missed',
  'client can mark old ringing call missed after 60 seconds'
);

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c3', true);
select pg_temp.assert_eq(
  (select count(*)::text from public.messages),
  '0',
  'non-member cannot read messages through RLS'
);
select pg_temp.assert_eq(
  (
    select count(*)::text
    from storage.objects
    where bucket_id = 'media'
      and name like (select ab_conversation_id::text || '/%' from test_ids)
  ),
  '0',
  'non-member cannot read conversation media through RLS'
);
select pg_temp.assert_raises($sql$
  insert into storage.objects(bucket_id, name, owner, metadata)
  select 'media', ab_conversation_id::text || '/00000000-0000-0000-0000-0000000000c3/file.jpg', '00000000-0000-0000-0000-0000000000c3', '{}'::jsonb
  from test_ids
$sql$, '42501', 'non-member cannot upload media into conversation');
select pg_temp.assert_raises($sql$
  select public.update_call_status((select id from call_ids), 'ended')
$sql$, '42501', 'non-call actor cannot update call status');

rollback;
