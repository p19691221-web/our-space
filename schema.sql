-- ============================================================
-- 我們的地方 · 資料庫結構
-- 在 Supabase 後台 → SQL Editor 貼上整份，按 Run。
-- 跑完後，再執行最下方的 setup_space(...) 設定邀請碼與管理碼。
--
-- 安全設計：所有資料表都不對外開放，網頁只能透過下面的函式存取，
-- 每個函式都會先核對成員身分。知道網址、拿到 anon key 也讀不到內容。
-- ============================================================

create table if not exists space_config (
  id               int primary key default 1 check (id = 1),
  name             text not null default '我們的地方',
  color            text not null default '#8a5a2b',
  welcome          text not null default '歡迎回來。',
  rules            text not null default '',
  ritual_label     text not null default '點一盞燈',   -- 留空則不顯示儀式
  ritual_done      text not null default '已點燈',
  topic_mode       text not null default 'admin' check (topic_mode in ('admin','all','off')),
  require_approval boolean not null default true,
  tz               text not null default 'Asia/Taipei',
  salt             text not null default gen_random_uuid()::text,
  invite_hash      text,
  admin_hash       text
);
insert into space_config (id) values (1) on conflict do nothing;

create table if not exists members (
  id         bigint generated always as identity primary key,
  token      uuid not null unique default gen_random_uuid(),
  nickname   text not null check (char_length(nickname) between 1 and 20),
  status     text not null default 'pending' check (status in ('pending','active','removed')),
  is_admin   boolean not null default false,
  created_at timestamptz not null default now()
);
create unique index if not exists members_nick_uq on members (lower(nickname)) where status <> 'removed';

create table if not exists messages (
  id         bigint generated always as identity primary key,
  member_id  bigint not null references members(id),
  body       text not null check (char_length(body) between 1 and 1000),
  deleted    boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists topics (
  day        date primary key,
  body       text not null check (char_length(body) between 1 and 200),
  member_id  bigint not null references members(id),
  created_at timestamptz not null default now()
);

create table if not exists rituals (
  day        date not null,
  member_id  bigint not null references members(id),
  created_at timestamptz not null default now(),
  primary key (day, member_id)
);

create table if not exists quotes (
  message_id bigint primary key references messages(id),
  added_by   bigint not null references members(id),
  created_at timestamptz not null default now()
);

-- 資料表一律不對外開放
alter table space_config enable row level security;
alter table members      enable row level security;
alter table messages     enable row level security;
alter table topics       enable row level security;
alter table rituals      enable row level security;
alter table quotes       enable row level security;
do $$ begin
  execute 'revoke all on space_config, members, messages, topics, rituals, quotes from public';
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on space_config, members, messages, topics, rituals, quotes from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on space_config, members, messages, topics, rituals, quotes from authenticated';
  end if;
end $$;

-- ---------- 內部工具 ----------
create or replace function _hash(p text) returns text
language sql stable security definer set search_path = public as $$
  select encode(sha256(convert_to(coalesce(p,'') || (select salt from space_config where id = 1), 'UTF8')), 'hex');
$$;

create or replace function _today() returns date
language sql stable security definer set search_path = public as $$
  select (now() at time zone (select tz from space_config where id = 1))::date;
$$;

create or replace function _me(p_token uuid, p_admin boolean default false) returns members
language plpgsql stable security definer set search_path = public as $$
declare m members;
begin
  select * into m from members where token = p_token and status = 'active';
  if not found then raise exception '尚未加入或已失去成員資格'; end if;
  if p_admin and not m.is_admin then raise exception '只有管理者可以這麼做'; end if;
  return m;
end $$;

-- ---------- 初始設定（只能在 SQL Editor 執行） ----------
create or replace function setup_space(p_invite text, p_admin text) returns text
language plpgsql security definer set search_path = public as $$
begin
  if char_length(p_invite) < 6 or char_length(p_admin) < 8 then
    raise exception '邀請碼至少 6 個字，管理碼至少 8 個字';
  end if;
  if p_invite = p_admin then raise exception '邀請碼和管理碼不能相同'; end if;
  update space_config set invite_hash = _hash(p_invite), admin_hash = _hash(p_admin) where id = 1;
  return '設定完成';
end $$;

-- ---------- 入口 ----------
create or replace function public_info() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('name', name, 'color', color, 'welcome', welcome,
                           'ready', invite_hash is not null)
  from space_config where id = 1;
$$;

create or replace function join_space(p_code text, p_nickname text) returns json
language plpgsql security definer set search_path = public as $$
declare c space_config; h text; m members; nick text := btrim(p_nickname);
begin
  select * into c from space_config where id = 1;
  if c.invite_hash is null then raise exception '這個空間還沒設定邀請碼'; end if;
  h := _hash(btrim(p_code));
  if h = c.admin_hash then
    insert into members (nickname, status, is_admin) values (nick, 'active', true) returning * into m;
  elsif h = c.invite_hash then
    insert into members (nickname, status) values (nick, case when c.require_approval then 'pending' else 'active' end) returning * into m;
  else
    perform pg_sleep(1);  -- 減緩猜碼
    raise exception '邀請碼不正確';
  end if;
  return json_build_object('token', m.token, 'status', m.status);
exception when unique_violation then
  raise exception '這個暱稱已經有人使用';
end $$;

create or replace function whoami(p_token uuid) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'id', m.id, 'nickname', m.nickname, 'status', m.status, 'is_admin', m.is_admin,
    'config', case when m.status = 'active' then json_build_object(
       'name', c.name, 'color', c.color, 'welcome', c.welcome, 'rules', c.rules,
       'ritual_label', c.ritual_label, 'ritual_done', c.ritual_done,
       'topic_mode', c.topic_mode, 'require_approval', c.require_approval, 'tz', c.tz) end)
  from members m, space_config c
  where m.token = p_token and c.id = 1 and m.status <> 'removed';
$$;

-- ---------- 聊天 ----------
create or replace function feed(p_token uuid, p_after bigint default 0) returns json
language plpgsql stable security definer set search_path = public as $$
declare me members := _me(p_token); r json;
begin
  select coalesce(json_agg(x order by x.id), '[]'::json) into r from (
    select msg.id, msg.member_id, mb.nickname, msg.body, msg.created_at,
           exists (select 1 from quotes q where q.message_id = msg.id) as quoted
    from messages msg join members mb on mb.id = msg.member_id
    where not msg.deleted and msg.id > coalesce(p_after, 0)
    order by msg.id desc limit 150
  ) x;
  return r;
end $$;

create or replace function post(p_token uuid, p_body text) returns json
language plpgsql security definer set search_path = public as $$
declare me members := _me(p_token); new_id bigint;
begin
  if (select count(*) from messages where member_id = me.id and created_at > now() - interval '1 minute') >= 20 then
    raise exception '說得太快了，請稍等一下';
  end if;
  insert into messages (member_id, body) values (me.id, btrim(p_body)) returning id into new_id;
  return json_build_object('id', new_id);
end $$;

-- ---------- 今天：話題與儀式 ----------
create or replace function today(p_token uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare me members := _me(p_token); d date := _today();
begin
  return json_build_object(
    'day', d,
    'topic', (select json_build_object('body', t.body, 'nickname', mb.nickname)
              from topics t join members mb on mb.id = t.member_id where t.day = d),
    'lit', (select coalesce(json_agg(mb.nickname order by r.created_at), '[]'::json)
            from rituals r join members mb on mb.id = r.member_id where r.day = d),
    'me_lit', exists (select 1 from rituals where day = d and member_id = me.id));
end $$;

create or replace function set_topic(p_token uuid, p_body text) returns json
language plpgsql security definer set search_path = public as $$
declare me members := _me(p_token); mode text := (select topic_mode from space_config where id = 1);
begin
  if mode = 'off' then raise exception '這個空間沒有開放話題'; end if;
  if mode = 'admin' and not me.is_admin then raise exception '只有管理者可以出題'; end if;
  insert into topics (day, body, member_id) values (_today(), btrim(p_body), me.id)
  on conflict (day) do update set body = excluded.body, member_id = excluded.member_id, created_at = now();
  return json_build_object('ok', true);
end $$;

create or replace function light(p_token uuid) returns json
language plpgsql security definer set search_path = public as $$
declare me members := _me(p_token);
begin
  insert into rituals (day, member_id) values (_today(), me.id) on conflict do nothing;
  return json_build_object('ok', true);
end $$;

-- ---------- 語錄 ----------
create or replace function quotes_list(p_token uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare me members := _me(p_token); r json;
begin
  select coalesce(json_agg(x order by x.created_at desc), '[]'::json) into r from (
    select q.message_id as id, msg.body, a.nickname, b.nickname as added_by, msg.created_at as said_at, q.created_at
    from quotes q join messages msg on msg.id = q.message_id
    join members a on a.id = msg.member_id join members b on b.id = q.added_by
    where not msg.deleted order by q.created_at desc limit 300
  ) x;
  return r;
end $$;

create or replace function add_quote(p_token uuid, p_message_id bigint) returns json
language plpgsql security definer set search_path = public as $$
declare me members := _me(p_token);
begin
  if not exists (select 1 from messages where id = p_message_id and not deleted) then raise exception '找不到這則訊息'; end if;
  insert into quotes (message_id, added_by) values (p_message_id, me.id) on conflict do nothing;
  return json_build_object('ok', true);
end $$;

-- ---------- 管理 ----------
create or replace function admin_members(p_token uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare me members := _me(p_token, true); r json;
begin
  select coalesce(json_agg(json_build_object('id', id, 'nickname', nickname, 'status', status,
         'is_admin', is_admin, 'created_at', created_at) order by status desc, created_at), '[]'::json)
  into r from members where status <> 'removed';
  return r;
end $$;

create or replace function admin_set_status(p_token uuid, p_member_id bigint, p_status text) returns json
language plpgsql security definer set search_path = public as $$
declare me members := _me(p_token, true);
begin
  if p_status not in ('active','removed') then raise exception '狀態不正確'; end if;
  if p_member_id = me.id then raise exception '不能變更自己的狀態'; end if;
  update members set status = p_status,
         token = case when p_status = 'removed' then gen_random_uuid() else token end
  where id = p_member_id;
  return json_build_object('ok', true);
end $$;

create or replace function admin_delete_message(p_token uuid, p_id bigint) returns json
language plpgsql security definer set search_path = public as $$
declare me members := _me(p_token, true);
begin
  update messages set deleted = true where id = p_id;
  delete from quotes where message_id = p_id;
  return json_build_object('ok', true);
end $$;

create or replace function admin_update_config(p_token uuid, p_cfg json) returns json
language plpgsql security definer set search_path = public as $$
declare me members := _me(p_token, true);
begin
  update space_config set
    name             = coalesce(nullif(btrim(p_cfg->>'name'), ''), name),
    color            = case when p_cfg->>'color' ~ '^#[0-9a-fA-F]{6}$' then p_cfg->>'color' else color end,
    welcome          = coalesce(p_cfg->>'welcome', welcome),
    rules            = coalesce(p_cfg->>'rules', rules),
    ritual_label     = coalesce(p_cfg->>'ritual_label', ritual_label),
    ritual_done      = coalesce(nullif(p_cfg->>'ritual_done', ''), ritual_done),
    topic_mode       = case when p_cfg->>'topic_mode' in ('admin','all','off') then p_cfg->>'topic_mode' else topic_mode end,
    require_approval = coalesce((p_cfg->>'require_approval')::boolean, require_approval)
  where id = 1;
  return json_build_object('ok', true);
end $$;

create or replace function admin_set_invite(p_token uuid, p_code text) returns json
language plpgsql security definer set search_path = public as $$
declare me members := _me(p_token, true);
begin
  if char_length(btrim(p_code)) < 6 then raise exception '邀請碼至少 6 個字'; end if;
  if _hash(btrim(p_code)) = (select admin_hash from space_config where id = 1) then raise exception '不能和管理碼相同'; end if;
  update space_config set invite_hash = _hash(btrim(p_code)) where id = 1;
  return json_build_object('ok', true);
end $$;

-- ---------- 權限：只開放網頁需要的函式 ----------
-- Supabase 預設會把新函式直接開放給 anon / authenticated，這裡先全部收回，
-- 再只開放下面列出的函式（setup_space、_hash 等內部函式不對外）。
revoke all on all functions in schema public from public;
do $$
declare f text;
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on all functions in schema public from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on all functions in schema public from authenticated';
  end if;
  foreach f in array array[
    'public_info()', 'join_space(text,text)', 'whoami(uuid)',
    'feed(uuid,bigint)', 'post(uuid,text)', 'today(uuid)', 'set_topic(uuid,text)', 'light(uuid)',
    'quotes_list(uuid)', 'add_quote(uuid,bigint)',
    'admin_members(uuid)', 'admin_set_status(uuid,bigint,text)', 'admin_delete_message(uuid,bigint)',
    'admin_update_config(uuid,json)', 'admin_set_invite(uuid,text)'] loop
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('grant execute on function %s to anon', f);
    end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated') then
      execute format('grant execute on function %s to authenticated', f);
    end if;
  end loop;
end $$;

-- ============================================================
-- 最後一步：把下面兩個碼換成你自己的，單獨執行這一行。
--   第一個是邀請碼（給成員），第二個是管理碼（只給你自己）。
--
-- select setup_space('換成邀請碼', '換成管理碼');
-- ============================================================
