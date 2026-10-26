-- 「話し合いで解決済み」の印を1組分つける例(ハルタソ と 鵺月 の プレシャス/クラシック のずれ)。
-- 自分(ハルタソ)から見た値: プレシャス +1(先に贈った) / クラシック -1(先に受け取った) を、差から引く。
insert into "03_fatewar_medals".pair_adj(a, b, rarity, qty)
select least(h.id, n.id), greatest(h.id, n.id), v.r, case when h.id < n.id then v.q else -v.q end
from "03_fatewar_medals".members h, "03_fatewar_medals".members n, (values ('precious', 1), ('classic', -1)) v(r, q)
where h.name = 'ハルタソ' and n.name = '鵺月'
on conflict (a, b, rarity) do update set qty = excluded.qty;
-- 印を外すとき: delete from "03_fatewar_medals".pair_adj where a in (select id from "03_fatewar_medals".members where name in ('ハルタソ','鵺月')) and b in (select id from "03_fatewar_medals".members where name in ('ハルタソ','鵺月'));
