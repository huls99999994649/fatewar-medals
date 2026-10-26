-- 取り置き(fw_state / fw_ver の変更)を元に戻すためのSQL。Supabase の SQL Editor で実行すると、変更前の関数に戻ります。
create or replace function public.fw_state(p_code text, p_member uuid default null, p_secret uuid default null)
returns json language plpgsql security definer set search_path to '' as $$
declare r json; ok boolean := false;
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
    'holdings', (select coalesce(json_agg(json_build_array(member_id, medal_id, qty)), '[]'::json) from "03_fatewar_medals".holdings where qty > 0),
    'gifts', (select coalesce(json_agg(x order by x.at desc), '[]'::json)
              from (select g.id, g.from_member as "from", g.to_member as "to", g.medal_id as medal, g.qty, g.created_at as at, (g.confirmed_at is not null) as ok
                    from "03_fatewar_medals".gifts g
                    where ok and (g.from_member = p_member or g.to_member = p_member)
                    order by g.created_at desc limit 300) x)
  ) into r;
  return r;
end $$;

-- 更新確認用の軽い「版番号」(変わったときだけ画面が fw_state を取り直す)
create or replace function public.fw_ver(p_code text, p_member uuid default null)
returns text language plpgsql security definer set search_path to '' as $$
declare v text;
begin
  perform "03_fatewar_medals".check_code(p_code);
  select md5(concat_ws('|',
    (select count(*)::text||':'||coalesce(sum(qty),0)::text||':'||coalesce(max(updated_at)::text,'') from "03_fatewar_medals".holdings),
    (select coalesce(string_agg(id::text||name, ',' order by id),'') from "03_fatewar_medals".members),
    (select count(*)::text||':'||coalesce(max(id),0)::text||':'||coalesce(max(confirmed_at)::text,'')
       from "03_fatewar_medals".gifts g where p_member is not null and (g.from_member=p_member or g.to_member=p_member))
  )) into v;
  return v;
end $$;

