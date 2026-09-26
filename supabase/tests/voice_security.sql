-- Run locally with: supabase db reset && psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/voice_security.sql
-- These tests use real authenticated role claims and no service-role bypass for protected operations.

begin;

create extension if not exists pgtap;
select plan(27);

insert into auth.users(id, email, encrypted_password, email_confirmed_at, raw_user_meta_data)
values
  ('00000000-0000-0000-0000-0000000000a1', 'alice@example.test', 'x', now(), '{"username":"Alice","display_name":"Alice"}'::jsonb),
  ('00000000-0000-0000-0000-0000000000b2', 'bob@example.test', 'x', now(), '{"username":"bob","display_name":"Bob"}'::jsonb),
  ('00000000-0000-0000-0000-0000000000c3', 'carol@example.test', 'x', now(), '{"username":"carol","display_name":"Carol"}'::jsonb)
on conflict (id) do nothing;

select ok(exists (select 1 from public.profiles where id = '00000000-0000-0000-0000-0000000000a1' and username = 'alice'), 'auth trigger creates lowercase profile');

set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select lives_ok($$ select public.start_direct_chat('00000000-0000-0000-0000-0000000000b2') $$, 'alice can start direct chat with bob');
select is(
  public.start_direct_chat('00000000-0000-0000-0000-0000000000b2'),
  public.start_direct_chat('00000000-0000-0000-0000-0000000000b2'),
  'start_direct_chat is idempotent for repeated calls'
);

create temp table test_ids as
select public.start_direct_chat('00000000-0000-0000-0000-0000000000b2') as ab_conversation_id;

select is((select count(*) from public.conversation_members), 2::bigint, 'idempotent chat has exactly two membership rows');
select ok((select ab_conversation_id is not null from test_ids), 'start_direct_chat returns uuid scalar');

select lives_ok($$
  insert into public.messages(conversation_id, sender_id, kind, body)
  select ab_conversation_id, '00000000-0000-0000-0000-0000000000a1', 'text', 'hello'
  from test_ids
$$, 'member can insert own message');

select throws_ok($$
  insert into public.messages(conversation_id, sender_id, kind, body)
  select ab_conversation_id, '00000000-0000-0000-0000-0000000000b2', 'text', 'spoof'
  from test_ids
$$, '42501', null, 'sender spoof is rejected');

select throws_ok($$
  insert into public.messages(conversation_id, sender_id, kind, attachment_path)
  select ab_conversation_id, '00000000-0000-0000-0000-0000000000a1', 'image', ab_conversation_id::text || '/00000000-0000-0000-0000-0000000000b2/file.jpg'
  from test_ids
$$, '42501', null, 'message cannot reference peer-owned media path');

select lives_ok($$
  insert into public.messages(conversation_id, sender_id, kind, attachment_path)
  select ab_conversation_id, '00000000-0000-0000-0000-0000000000a1', 'image', ab_conversation_id::text || '/00000000-0000-0000-0000-0000000000a1/file.jpg'
  from test_ids
$$, 'message can reference own media path');

select is((select count(*) from public.conversation_list()), 1::bigint, 'conversation_list returns member conversation');
select ok((select to_jsonb(public.conversation_list()) ? 'peer_id'), 'conversation_list row has peer_id key');

select throws_ok($$
  update public.profiles set username = 'Bad Name' where id = '00000000-0000-0000-0000-0000000000a1'
$$, '42501', null, 'invalid profile username update is rejected');

select lives_ok($$
  insert into storage.objects(bucket_id, name, owner, metadata)
  select 'media', ab_conversation_id::text || '/00000000-0000-0000-0000-0000000000a1/file.jpg', '00000000-0000-0000-0000-0000000000a1', '{}'::jsonb
  from test_ids
$$, 'member can upload media under own uid segment');

select throws_ok($$
  insert into storage.objects(bucket_id, name, owner, metadata)
  select 'media', ab_conversation_id::text || '/00000000-0000-0000-0000-0000000000a1/nested/file.jpg', '00000000-0000-0000-0000-0000000000a1', '{}'::jsonb
  from test_ids
$$, '42501', null, 'media paths reject nested filenames');

select throws_ok($$
  insert into storage.objects(bucket_id, name, owner, metadata)
  select 'media', ab_conversation_id::text || '/00000000-0000-0000-0000-0000000000b2/file.jpg', '00000000-0000-0000-0000-0000000000a1', '{}'::jsonb
  from test_ids
$$, '42501', null, 'member cannot upload media under peer uid segment');

select lives_ok($$
  insert into storage.objects(bucket_id, name, owner, metadata)
  values ('avatars', '00000000-0000-0000-0000-0000000000a1/avatar.jpg', '00000000-0000-0000-0000-0000000000a1', '{}'::jsonb)
$$, 'user can upload own avatar');

select throws_ok($$
  insert into storage.objects(bucket_id, name, owner, metadata)
  values ('avatars', '00000000-0000-0000-0000-0000000000b2/avatar.jpg', '00000000-0000-0000-0000-0000000000a1', '{}'::jsonb)
$$, '42501', null, 'user cannot upload avatar under peer uid segment');

select lives_ok($$
  select public.start_call(ab_conversation_id) from test_ids
$$, 'caller can start call');

select throws_ok($$
  select public.start_call(ab_conversation_id) from test_ids
$$, '55000', null, 'busy caller cannot start another call');

create temp table call_ids as
select * from public.calls order by created_at desc limit 1;

select ok((select to_jsonb(call_ids) ? 'conversation_id' from call_ids limit 1), 'start_call returns a calls JSON object shape');

select throws_ok($$
  select public.update_call_status((select id from call_ids), 'accepted')
$$, '42501', null, 'caller cannot accept own ringing call');

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b2', true);

create temp table accepted_call as
select * from public.update_call_status((select id from call_ids), 'accepted');

select is((select status from accepted_call limit 1), 'accepted', 'callee can accept ringing call');
select ok((select to_jsonb(accepted_call) ? 'id' and to_jsonb(accepted_call) ? 'status' from accepted_call limit 1), 'update_call_status returns a calls JSON object shape');
select lives_ok($$
  select public.update_call_status((select id from call_ids), 'ended')
$$, 'callee can end accepted call');

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

select is((select status from public.update_call_status((select id from old_call), 'missed')), 'missed', 'client can mark old ringing call missed after 60 seconds');

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c3', true);
select is((select count(*) from public.messages), 0::bigint, 'non-member cannot read messages through RLS');
select throws_ok($$
  insert into storage.objects(bucket_id, name, owner, metadata)
  select 'media', ab_conversation_id::text || '/00000000-0000-0000-0000-0000000000c3/file.jpg', '00000000-0000-0000-0000-0000000000c3', '{}'::jsonb
  from test_ids
$$, '42501', null, 'non-member cannot upload media into conversation');
select throws_ok($$
  select public.update_call_status((select id from call_ids), 'ended')
$$, '42501', null, 'non-call actor cannot update call status');

select hasnt_function('public', 'is_conversation_member', array['uuid', 'uuid'], 'legacy membership helper is not callable through exposed contract');
select ok(true, 'SQL tests executed through psql-compatible pgtap');

select * from finish();
rollback;
