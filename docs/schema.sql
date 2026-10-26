-- 恐怖のギフト交換所(メダル交換マッチングアプリ) データベース構成
-- Supabase の SQL Editor に貼り付けて実行すると、同じ構成を作れます。
-- 注意: ギルドコード・メンバー情報・パスワードなどの実データはこのファイルに含めていません。

create extension if not exists pgcrypto with schema extensions;
create schema if not exists "03_fatewar_medals";

-- ---------- 表 ----------
create table "03_fatewar_medals".settings (
  key text primary key,
  value text not null
);

create table "03_fatewar_medals".themes (
  theme_no smallint primary key,
  name text not null
);

create table "03_fatewar_medals".medals (
  id smallint primary key,
  theme_no smallint not null references "03_fatewar_medals".themes(theme_no),
  pos smallint not null,
  name text not null,
  rarity text not null check (rarity in ('precious','classic','legend')),
  unique (theme_no, pos)
);

create table "03_fatewar_medals".members (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  secret uuid not null default gen_random_uuid(),   -- 端末に保存される合言葉(画面には出さない)
  created_at timestamptz not null default now(),
  pw_hash text                                      -- パスワードのハッシュ(bcrypt)
);

create table "03_fatewar_medals".holdings (
  member_id uuid not null references "03_fatewar_medals".members(id) on delete cascade,
  medal_id smallint not null references "03_fatewar_medals".medals(id),
  qty smallint not null default 0 check (qty >= 0),
  updated_at timestamptz not null default now(),
  primary key (member_id, medal_id)
);

create table "03_fatewar_medals".gifts (
  id bigserial primary key,
  from_member uuid not null references "03_fatewar_medals".members(id),
  to_member uuid not null references "03_fatewar_medals".members(id),
  medal_id smallint not null references "03_fatewar_medals".medals(id),
  qty smallint not null default 1 check (qty > 0),
  created_at timestamptz not null default now(),
  confirmed_at timestamptz                          -- 受け取り側が確認した時刻
);

-- 「話し合いで解決済み」の印。aがbに贈った枚数−受け取った枚数のうち、そのレア度のqty枚分は差から引く(a<b の向きで1行)。
-- メダルの枚数・交換履歴は書き換えず、取り置き/お返し待ち/交換済みの判定にだけ使う。
create table if not exists "03_fatewar_medals".pair_adj (
  a uuid not null references "03_fatewar_medals".members(id) on delete cascade,
  b uuid not null references "03_fatewar_medals".members(id) on delete cascade,
  rarity text not null check (rarity in ('precious','classic','legend')),
  qty int not null check (qty <> 0),
  primary key (a, b, rarity),
  check (a < b)
);
alter table "03_fatewar_medals".pair_adj enable row level security;
revoke all on "03_fatewar_medals".pair_adj from anon, authenticated;

-- 表への直接アクセスは禁止(ポリシーなし)。画面は下の関数(RPC)だけを使います。
alter table "03_fatewar_medals".settings enable row level security;
alter table "03_fatewar_medals".themes   enable row level security;
alter table "03_fatewar_medals".medals   enable row level security;
alter table "03_fatewar_medals".members  enable row level security;
alter table "03_fatewar_medals".holdings enable row level security;
alter table "03_fatewar_medals".gifts    enable row level security;

-- ---------- 内部用の確認関数 ----------
create or replace function "03_fatewar_medals".check_code(p_code text)
returns void language plpgsql security definer set search_path to '' as $$
begin
  if p_code is null or not exists (
    select 1 from "03_fatewar_medals".settings
    where key = 'guild_code' and value = upper(btrim(p_code))
  ) then
    raise exception 'invalid guild code' using errcode = '28000';
  end if;
end $$;

create or replace function "03_fatewar_medals".check_member(p_member uuid, p_secret uuid)
returns void language plpgsql security definer set search_path to '' as $$
begin
  if p_member is null or p_secret is null or not exists (
    select 1 from "03_fatewar_medals".members where id = p_member and secret = p_secret
  ) then
    raise exception 'invalid member' using errcode = '28000';
  end if;
end $$;

-- ---------- 画面から呼ぶ関数(RPC) ----------
-- 全体の状態を返す(自分に関係する交換履歴だけを含む)。
-- 取り置き表示: 「あなたに贈る義務がある相手」の候補メダルを、他の人の画面から隠す(表示のみ。実際の枚数は変えない)
-- 清算はレア度ごと(同じレア度同士で交換する取り決め)。隠すのは、次の条件をすべて満たすときだけ。迷う場合は隠さない。
--   Y(もらう側) と X(贈る側) のペアで、あるレア度 r について
--   (1) 差 dr = (Y が X に贈った枚数 − X が Y に贈った枚数 − 解決済みの印 pair_adj) > 0
--   (2) X の余り(2枚以上)のうち、Y が持っていない、レア度 r のメダルの種類数 <= dr
--   → この候補は Y のために取り置き、Y 以外の人(X 本人も除く)には、その1枚分の余りを見せない。
-- 'adj' には、自分のペアの印だけを [相手, レア度, 自分から見た枚数] で返す(他の人の分は返さない)。
create or replace function public.fw_state(p_code text, p_member uuid default null, p_secret uuid default null)
returns json language plpgsql security definer set search_path to '' as $$
declare rj json; ok boolean := false;
begin
  perform "03_fatewar_medals".check_code(p_code);
  if p_member is not null and p_secret is not null then
    perform "03_fatewar_medals".check_member(p_member, p_secret);
    ok := true;
  end if;
  select json_build_object(
    'themes', (select coalesce(json_agg(json_build_object('no', theme_no, 'name', name) order by theme_no), '[]'::json) from "03_fatewar_medals".themes),
    'medals', (select coalesce(json_agg(json_build_object('id', id, 'theme', theme_no, 'pos', pos, 'name', name, 'rarity', rarity) order by id), '[]'::json) from "03_fatewar_medals".medals),
    'members', (select coalesce(json_agg(json_build_object('id', id, 'name', name) order by created_at), '[]'::json) from "03_fatewar_medals".members),
    'holdings', (
      with sr as (
        select g.from_member as y, g.to_member as x, m.rarity as r, sum(g.qty)::int as q
        from "03_fatewar_medals".gifts g join "03_fatewar_medals".medals m on m.id = g.medal_id group by 1, 2, 3),
      adjd as (
        select a as y, b as x, rarity as r, qty from "03_fatewar_medals".pair_adj
        union all
        select b, a, rarity, -qty from "03_fatewar_medals".pair_adj),
      keys as (
        select y, x, r from sr union select x, y, r from sr union select y, x, r from adjd),
      -- (y→x) のレア度ごとの差 = yが贈った − xが贈った − 解決済みの印
      cap as (
        select k.y, k.x, k.r,
               coalesce(a.q, 0) - coalesce(b.q, 0) - coalesce(ad.qty, 0) as c
        from keys k
        left join sr a on a.y = k.y and a.x = k.x and a.r = k.r
        left join sr b on b.y = k.x and b.x = k.y and b.r = k.r
        left join adjd ad on ad.y = k.y and ad.x = k.x and ad.r = k.r
        where coalesce(a.q, 0) - coalesce(b.q, 0) - coalesce(ad.qty, 0) > 0),
      cand as (
        select c.y, c.x, c.r, h.medal_id
        from cap c
        join "03_fatewar_medals".holdings h on h.member_id = c.x and h.qty >= 2
        join "03_fatewar_medals".medals m on m.id = h.medal_id and m.rarity = c.r
        where not exists (
          select 1 from "03_fatewar_medals".holdings hy
          where hy.member_id = c.y and hy.medal_id = h.medal_id and hy.qty > 0)),
      cnt as (select y, x, r, count(*)::int as n from cand group by 1, 2, 3),
      res as (
        select cd.y, cd.x, cd.medal_id
        from cand cd
        join cnt on cnt.y = cd.y and cnt.x = cd.x and cnt.r = cd.r
        join cap  on cap.y = cd.y and cap.x = cd.x and cap.r = cd.r
        where cnt.n <= cap.c),
      hide as (
        select x, medal_id, count(*)::int as n
        from res
        where ok and y <> p_member and x <> p_member
        group by 1, 2)
      select coalesce(json_agg(json_build_array(
               h.member_id, h.medal_id,
               case when hd.n is null then h.qty else greatest(1, h.qty - hd.n) end)), '[]'::json)
      from "03_fatewar_medals".holdings h
      left join hide hd on hd.x = h.member_id and hd.medal_id = h.medal_id
      where h.qty > 0),
    'gifts', (select coalesce(json_agg(x order by x.at desc), '[]'::json)
              from (select g.id, g.from_member as "from", g.to_member as "to", g.medal_id as medal, g.qty, g.created_at as at, (g.confirmed_at is not null) as ok
                    from "03_fatewar_medals".gifts g
                    where ok and (g.from_member = p_member or g.to_member = p_member)
                    order by g.created_at desc limit 300) x),
    -- 自分のペアの「話し合いで解決済み」の印: [相手, レア度, 自分から見た枚数]
    'adj', (select coalesce(json_agg(json_build_array(z.o, z.r, z.q)), '[]'::json)
            from (select b as o, rarity as r, qty as q from "03_fatewar_medals".pair_adj where ok and a = p_member
                  union all
                  select a, rarity, -qty from "03_fatewar_medals".pair_adj where ok and b = p_member) z)
  ) into rj;
  return rj;
end $$;

create or replace function public.fw_ver(p_code text, p_member uuid default null)
returns text language plpgsql security definer set search_path to '' as $$
declare v text;
begin
  perform "03_fatewar_medals".check_code(p_code);
  select md5(concat_ws('|',
    (select count(*)::text||':'||coalesce(sum(qty),0)::text||':'||coalesce(max(updated_at)::text,'') from "03_fatewar_medals".holdings),
    (select coalesce(string_agg(id::text||name, ',' order by id),'') from "03_fatewar_medals".members),
    (select count(*)::text||':'||coalesce(max(id),0)::text||':'||coalesce(max(confirmed_at)::text,'')
       from "03_fatewar_medals".gifts g where p_member is not null and (g.from_member=p_member or g.to_member=p_member)),
    (select count(*)::text||':'||coalesce(max(id),0)::text from "03_fatewar_medals".gifts),
    -- 印は全員の取り置きの判定に影響するため、全体の件数と内容を含める
    (select coalesce(string_agg(a::text||b::text||rarity||qty::text, ',' order by a, b, rarity),'') from "03_fatewar_medals".pair_adj)
  )) into v;
  return v;
end $$;

-- 新規参加(名前+パスワード)。人数の上限と受付の締め切りに対応。
--   settings の max_members(既定30) / join_open('false' で新規参加を締め切る)
create or replace function public.fw_join(p_code text, p_name text, p_password text)
returns json language plpgsql security definer set search_path to '' as $$
declare v_name text := btrim(p_name); m record; v_max int; v_open text;
begin
  perform "03_fatewar_medals".check_code(p_code);
  if v_name is null or char_length(v_name) not between 1 and 20 then raise exception 'invalid name'; end if;
  if p_password is null or char_length(p_password) < 4 or char_length(p_password) > 64 then raise exception 'invalid password'; end if;
  if exists (select 1 from "03_fatewar_medals".members where name = v_name) then raise exception 'name taken'; end if;
  perform pg_advisory_xact_lock(hashtext('fw_join'));   -- 同時に参加が重なっても上限を超えないよう順番に処理
  select value into v_open from "03_fatewar_medals".settings where key = 'join_open';
  if coalesce(lower(btrim(v_open)), 'true') = 'false' then raise exception 'registration closed'; end if;
  select coalesce((select nullif(btrim(value), '')::int from "03_fatewar_medals".settings where key = 'max_members'), 30) into v_max;
  if (select count(*) from "03_fatewar_medals".members) >= v_max then raise exception 'guild full'; end if;
  insert into "03_fatewar_medals".members (name, pw_hash) values (v_name, extensions.crypt(p_password, extensions.gen_salt('bf')))
    returning id, secret into m;
  return json_build_object('member_id', m.id, 'secret', m.secret, 'name', v_name);
end $$;

-- ログイン(名前+パスワード。パスワード未設定の旧アカウントは合言葉で入れる)
create or replace function public.fw_login(p_code text, p_name text, p_password text)
returns json language plpgsql security definer set search_path to '' as $$
declare m record; ok boolean;
begin
  perform "03_fatewar_medals".check_code(p_code);
  select id, name, secret, pw_hash into m from "03_fatewar_medals".members where name = btrim(p_name);
  if not found then raise exception 'invalid member' using errcode = '28000'; end if;
  if m.pw_hash is null then ok := (m.secret::text = btrim(coalesce(p_password,'')));
  else ok := (m.pw_hash = extensions.crypt(coalesce(p_password,''), m.pw_hash)); end if;
  if not ok then raise exception 'invalid member' using errcode = '28000'; end if;
  return json_build_object('member_id', m.id, 'name', m.name, 'secret', m.secret, 'has_pw', m.pw_hash is not null);
end $$;

create or replace function public.fw_has_pw(p_code text, p_member uuid, p_secret uuid)
returns boolean language plpgsql security definer set search_path to '' as $$
declare v boolean;
begin
  perform "03_fatewar_medals".check_code(p_code);
  select pw_hash is not null into v from "03_fatewar_medals".members where id = p_member and secret = p_secret;
  if v is null then raise exception 'invalid member' using errcode = '28000'; end if;
  return v;
end $$;

create or replace function public.fw_set_password(p_code text, p_member uuid, p_secret uuid, p_password text)
returns boolean language plpgsql security definer set search_path to '' as $$
begin
  perform "03_fatewar_medals".check_code(p_code);
  if p_password is null or char_length(p_password) < 4 or char_length(p_password) > 64 then raise exception 'invalid password'; end if;
  update "03_fatewar_medals".members set pw_hash = extensions.crypt(p_password, extensions.gen_salt('bf'))
   where id = p_member and secret = p_secret;
  if not found then raise exception 'invalid member' using errcode = '28000'; end if;
  return true;
end $$;

create or replace function public.fw_rename(p_code text, p_member uuid, p_secret uuid, p_name text)
returns json language plpgsql security definer set search_path to '' as $$
declare v_name text := btrim(p_name);
begin
  perform "03_fatewar_medals".check_code(p_code);
  if v_name is null or char_length(v_name) not between 1 and 20 then raise exception 'invalid name'; end if;
  if not exists (select 1 from "03_fatewar_medals".members where id = p_member and secret = p_secret) then
    raise exception 'invalid member' using errcode = '28000';
  end if;
  if exists (select 1 from "03_fatewar_medals".members where name = v_name and id <> p_member) then raise exception 'name taken'; end if;
  update "03_fatewar_medals".members set name = v_name where id = p_member;
  return json_build_object('name', v_name);
end $$;

-- メダルの所持枚数を登録(0〜999枚)
create or replace function public.fw_set_qty(p_code text, p_member uuid, p_secret uuid, p_items jsonb)
returns integer language plpgsql security definer set search_path to '' as $$
declare it jsonb; n integer := 0;
begin
  perform "03_fatewar_medals".check_code(p_code);
  perform "03_fatewar_medals".check_member(p_member, p_secret);
  for it in select * from jsonb_array_elements(p_items) loop
    insert into "03_fatewar_medals".holdings (member_id, medal_id, qty, updated_at)
    values (p_member, (it->>'medal_id')::smallint,
            greatest(0, least(999, (it->>'qty')::int))::smallint, now())
    on conflict (member_id, medal_id)
    do update set qty = excluded.qty, updated_at = now();
    n := n + 1;
  end loop;
  return n;
end $$;

-- 「贈った」を記録(贈る側が最低1枚残る範囲。相手の枚数が増え、自分の枚数が減る)
create or replace function public.fw_gift(p_code text, p_member uuid, p_secret uuid, p_to uuid, p_medal integer, p_qty integer default 1)
returns json language plpgsql security definer set search_path to '' as $$
declare have int;
begin
  perform "03_fatewar_medals".check_code(p_code);
  perform "03_fatewar_medals".check_member(p_member, p_secret);
  if p_to = p_member then raise exception 'cannot gift to self'; end if;
  if p_qty is null or p_qty < 1 then raise exception 'invalid qty'; end if;
  if not exists (select 1 from "03_fatewar_medals".members where id = p_to) then raise exception 'unknown recipient'; end if;
  select qty into have from "03_fatewar_medals".holdings
   where member_id = p_member and medal_id = p_medal for update;
  if coalesce(have, 0) - p_qty < 1 then raise exception 'not enough spare'; end if;
  update "03_fatewar_medals".holdings set qty = qty - p_qty, updated_at = now()
   where member_id = p_member and medal_id = p_medal;
  insert into "03_fatewar_medals".holdings as h (member_id, medal_id, qty, updated_at)
  values (p_to, p_medal, p_qty, now())
  on conflict (member_id, medal_id)
  do update set qty = h.qty + excluded.qty, updated_at = now();
  insert into "03_fatewar_medals".gifts (from_member, to_member, medal_id, qty)
  values (p_member, p_to, p_medal, p_qty);
  return json_build_object('ok', true);
end $$;

-- 「受け取りを確認」(記録のみ。枚数は変わらない)
create or replace function public.fw_confirm(p_code text, p_member uuid, p_secret uuid, p_gift bigint)
returns boolean language plpgsql security definer set search_path to '' as $$
begin
  perform "03_fatewar_medals".check_code(p_code);
  if not exists (select 1 from "03_fatewar_medals".members where id = p_member and secret = p_secret) then
    raise exception 'invalid member' using errcode = '28000';
  end if;
  update "03_fatewar_medals".gifts set confirmed_at = coalesce(confirmed_at, now())
   where id = p_gift and to_member = p_member;
  if not found then raise exception 'invalid gift'; end if;
  return true;
end $$;

-- 画面(匿名キー)から呼べるのは fw_* だけ
revoke all on function public.fw_state(text,uuid,uuid), public.fw_ver(text,uuid), public.fw_join(text,text,text),
  public.fw_login(text,text,text), public.fw_has_pw(text,uuid,uuid), public.fw_set_password(text,uuid,uuid,text),
  public.fw_rename(text,uuid,uuid,text), public.fw_set_qty(text,uuid,uuid,jsonb),
  public.fw_gift(text,uuid,uuid,uuid,integer,integer), public.fw_confirm(text,uuid,uuid,bigint) from public;
grant execute on function public.fw_state(text,uuid,uuid), public.fw_ver(text,uuid), public.fw_join(text,text,text),
  public.fw_login(text,text,text), public.fw_has_pw(text,uuid,uuid), public.fw_set_password(text,uuid,uuid,text),
  public.fw_rename(text,uuid,uuid,text), public.fw_set_qty(text,uuid,uuid,jsonb),
  public.fw_gift(text,uuid,uuid,uuid,integer,integer), public.fw_confirm(text,uuid,uuid,bigint) to anon, authenticated;

-- ギルドコードは次のように設定します(英数字の大文字。値は自分で決める):
--   insert into "03_fatewar_medals".settings(key,value) values ('guild_code','ここに合言葉');
-- 人数の上限(既定30)と、新規参加の受付(true=受付中 / false=締め切り)も settings で変えられます:
--   insert into "03_fatewar_medals".settings(key,value) values ('max_members','30'),('join_open','true');
--   update "03_fatewar_medals".settings set value='50' where key='max_members';   -- 上限を変える
--   update "03_fatewar_medals".settings set value='false' where key='join_open';   -- 新規参加を締め切る
-- ※ Supabase の「Exposed schemas」に 03_fatewar_medals を追加する必要はありません(関数が public にあるため)。
