-- レア度ごとの清算(fw_state / fw_ver の変更)を元に戻すためのSQL。直前(取り置きのみの版)の関数に戻ります。
-- pair_adj の表は残しますが、元の関数は参照しないので影響しません(不要なら drop table "03_fatewar_medals".pair_adj;)。
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
      with s as (
        select g.from_member as y, g.to_member as x, sum(g.qty)::int as q
        from "03_fatewar_medals".gifts g group by 1, 2),
      sr as (
        select g.from_member as y, g.to_member as x, m.rarity as r, sum(g.qty)::int as q
        from "03_fatewar_medals".gifts g join "03_fatewar_medals".medals m on m.id = g.medal_id group by 1, 2, 3),
      dtot as (
        select a.y, a.x, a.q - coalesce(b.q, 0) as d
        from s a left join s b on b.y = a.x and b.x = a.y),
      drar as (
        select a.y, a.x, a.r, a.q - coalesce(b.q, 0) as dr
        from sr a left join sr b on b.y = a.x and b.x = a.y and b.r = a.r),
      cap as (
        select t.y, t.x, v.r, least(t.d, v.dr) as c
        from dtot t join drar v on v.y = t.y and v.x = t.x
        where t.d > 0 and v.dr > 0),
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
                    order by g.created_at desc limit 300) x)
  ) into rj;
  return rj;
end $$;

-- 版番号: 取り置きは全員の贈り記録に依存するため、全体の贈りの件数と最大IDも含める
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
    (select count(*)::text||':'||coalesce(max(id),0)::text from "03_fatewar_medals".gifts)
  )) into v;
  return v;
end $$;
