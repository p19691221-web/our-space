-- ============================================================
-- 我們的地方 · 通話（語音／視訊）
-- 已經架好空間的人：在 Supabase → SQL Editor 貼上整份，按 Run，只要一次。
-- （新架的空間直接跑最新的 schema.sql 就好，裡面已經包含這段。）
--
-- 通話本身是成員之間點對點連線，聲音畫面不經過資料庫；
-- 資料庫只負責「誰在通話裡」和交換建立連線用的資料，每次都先核對成員身分。
-- ============================================================

create table if not exists call_peers (
  peer_id   uuid primary key,
  member_id bigint not null references members(id),
  mic       boolean not null default true,
  cam       boolean not null default false,
  joined_at timestamptz not null default now(),
  seen_at   timestamptz not null default now()
);

create table if not exists call_signals (
  id         bigint generated always as identity primary key,
  to_peer    uuid not null,
  from_peer  uuid not null,
  kind       text not null check (kind in ('offer','answer')),
  body       text not null check (char_length(body) <= 30000),
  created_at timestamptz not null default now()
);
create index if not exists call_signals_to on call_signals (to_peer, id);

alter table call_peers   enable row level security;
alter table call_signals enable row level security;
do $$ begin
  execute 'revoke all on call_peers, call_signals from public';
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on call_peers, call_signals from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on call_peers, call_signals from authenticated';
  end if;
end $$;

-- 清掉斷線超過 30 秒的人、兩分鐘前的連線資料
create or replace function _call_clean() returns void
language sql security definer set search_path = public as $$
  delete from call_peers where seen_at < now() - interval '30 seconds';
  delete from call_signals where created_at < now() - interval '2 minutes';
$$;

-- 現在有誰在通話裡（還沒加入的人看的）
create or replace function call_who(p_token uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare me members := _me(p_token); r json;
begin
  select coalesce(json_agg(m.nickname order by p.joined_at), '[]'::json) into r
  from call_peers p join members m on m.id = p.member_id
  where m.status = 'active' and p.seen_at > now() - interval '30 seconds';
  return r;
end $$;

create or replace function call_join(p_token uuid, p_cam boolean default false) returns json
language plpgsql security definer set search_path = public as $$
declare me members := _me(p_token); pid uuid := gen_random_uuid();
begin
  perform _call_clean();
  delete from call_peers where member_id = me.id;  -- 同一個人只保留最新加入的那個畫面
  if (select count(*) from call_peers) >= 8 then raise exception '通話已滿（最多 8 人）'; end if;
  insert into call_peers (peer_id, member_id, cam) values (pid, me.id, coalesce(p_cam, false));
  return json_build_object('peer', pid);
end $$;

create or replace function call_poll(p_token uuid, p_peer uuid, p_after bigint default 0,
                                     p_mic boolean default null, p_cam boolean default null) returns json
language plpgsql security definer set search_path = public as $$
declare me members := _me(p_token);
begin
  update call_peers set seen_at = now(), mic = coalesce(p_mic, mic), cam = coalesce(p_cam, cam)
  where peer_id = p_peer and member_id = me.id;
  if not found then return json_build_object('gone', true); end if;
  delete from call_peers where seen_at < now() - interval '30 seconds';
  delete from call_signals where to_peer = p_peer and id <= coalesce(p_after, 0);
  return json_build_object(
    'peers', (select coalesce(json_agg(json_build_object(
                'peer', p.peer_id, 'member', m.id, 'nickname', m.nickname, 'mic', p.mic, 'cam', p.cam)
                order by p.joined_at), '[]'::json)
              from call_peers p join members m on m.id = p.member_id
              where m.status = 'active' and p.peer_id <> p_peer),
    'signals', (select coalesce(json_agg(json_build_object(
                'id', s.id, 'from', s.from_peer, 'kind', s.kind, 'body', s.body) order by s.id), '[]'::json)
              from call_signals s where s.to_peer = p_peer and s.id > coalesce(p_after, 0)));
end $$;

create or replace function call_send(p_token uuid, p_peer uuid, p_to uuid, p_kind text, p_body text) returns json
language plpgsql security definer set search_path = public as $$
declare me members := _me(p_token);
begin
  if not exists (select 1 from call_peers where peer_id = p_peer and member_id = me.id) then
    raise exception '你已經不在通話裡';
  end if;
  if not exists (select 1 from call_peers where peer_id = p_to) then
    return json_build_object('ok', false);
  end if;
  if (select count(*) from call_signals where from_peer = p_peer and created_at > now() - interval '10 seconds') >= 40 then
    raise exception '連線太頻繁，請稍等';
  end if;
  insert into call_signals (to_peer, from_peer, kind, body) values (p_to, p_peer, p_kind, p_body);
  return json_build_object('ok', true);
end $$;

create or replace function call_leave(p_token uuid, p_peer uuid) returns json
language plpgsql security definer set search_path = public as $$
declare me members := _me(p_token);
begin
  delete from call_peers where peer_id = p_peer and member_id = me.id;
  delete from call_signals where to_peer = p_peer or from_peer = p_peer;
  return json_build_object('ok', true);
end $$;

-- 權限：只開放網頁需要的五個函式
do $$
declare f text;
begin
  execute 'revoke all on function _call_clean() from public';
  foreach f in array array[
    'call_who(uuid)', 'call_join(uuid,boolean)', 'call_poll(uuid,uuid,bigint,boolean,boolean)',
    'call_send(uuid,uuid,uuid,text,text)', 'call_leave(uuid,uuid)'] loop
    execute format('revoke all on function %s from public', f);
  end loop;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function _call_clean() from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on function _call_clean() from authenticated';
  end if;
  foreach f in array array[
    'call_who(uuid)', 'call_join(uuid,boolean)', 'call_poll(uuid,uuid,bigint,boolean,boolean)',
    'call_send(uuid,uuid,uuid,text,text)', 'call_leave(uuid,uuid)'] loop
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('grant execute on function %s to anon', f);
    end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated') then
      execute format('grant execute on function %s to authenticated', f);
    end if;
  end loop;
end $$;
