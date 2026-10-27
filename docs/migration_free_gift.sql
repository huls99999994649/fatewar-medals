-- 「あげた」の印: メンバー詳細画面から贈った記録は free=true。
-- 「あと○枚もらっていません」の計算・取り置きの計算に入れない(履歴には残る)。
alter table "03_fatewar_medals".gifts add column if not exists free boolean not null default false;

drop function if exists public.fw_gift(text,uuid,uuid,uuid,integer,integer);
create or replace function public.fw_gift(p_code text, p_member uuid, p_secret uuid, p_to uuid, p_medal integer, p_qty integer default 1, p_free boolean default false)
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
  insert into "03_fatewar_medals".gifts (from_member, to_member, medal_id, qty, free)
  values (p_member, p_to, p_medal, p_qty, coalesce(p_free, false));
  return json_build_object('ok', true);
end $$;

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
        from "03_fatewar_medals".gifts g join "03_fatewar_medals".medals m on m.id = g.medal_id where not g.free group by 1, 2, 3),
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
              from (select g.id, g.from_member as "from", g.to_member as "to", g.medal_id as medal, g.qty, g.created_at as at, (g.confirmed_at is not null) as ok, g.free
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
    (select count(*)::text||':'||coalesce(max(id),0)::text||':'||coalesce(max(confirmed_at)::text,'')||':'||count(*) filter (where g.free)::text
       from "03_fatewar_medals".gifts g where p_member is not null and (g.from_member=p_member or g.to_member=p_member)),
    (select count(*)::text||':'||coalesce(max(id),0)::text||':'||count(*) filter (where free)::text from "03_fatewar_medals".gifts),
    -- 印は全員の取り置きの判定に影響するため、全体の件数と内容を含める
    (select coalesce(string_agg(a::text||b::text||rarity||qty::text, ',' order by a, b, rarity),'') from "03_fatewar_medals".pair_adj)
  )) into v;
  return v;
end $$;

revoke all on function public.fw_gift(text,uuid,uuid,uuid,integer,integer,boolean) from public;
grant execute on function public.fw_gift(text,uuid,uuid,uuid,integer,integer,boolean) to anon, authenticated;
