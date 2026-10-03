-- Only fixed claims have the 3-drops-per-member limit; soft claims can be dropped any number of times.
CREATE OR REPLACE FUNCTION "public"."joiner_unclaim"("p_handle" "text", "p_pin" "text", "p_claim" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  a  record;
  c  public.claims%rowtype;
  g  public.group_orders%rowtype;
  d  public.drops%rowtype;
  full_code text;
  keep boolean;
  n_drops int;
begin
  select * into a from public._joiner_auth(p_handle, p_pin);
  if a.err is not null then return jsonb_build_object('error', a.err); end if;

  select * into c from public.claims where id = p_claim and joiner_id = a.j_id;
  if not found or c.status <> 'filled' then return jsonb_build_object('error', 'not_found'); end if;
  select * into g from public.group_orders where id = c.group_order_id;
  select * into d from public.drops where id = g.drop_id;
  if g.status <> 'Claims Open'
     or (d.deadline is not null and now() > public.drop_due_at(d.deadline, d.deadline_time)) then
    return jsonb_build_object('error', 'closed');
  end if;
  full_code := case when d.type = 'Merch' then null when d.solo_unit = 'Unit' then 'OT4' else 'OT8' end;

  -- Dropping an OT8/OT4 that a fixed or soft claimer switched to puts their fixed/soft claims back, in their old
  -- places in line. That isn't a drop, so it doesn't count toward their 3 drops.
  if c.switched and c.member_code = full_code then
    perform public._switch_back(c.group_order_id, a.j_id);
    return jsonb_build_object('ok', true, 'switched_back', true);
  end if;

  -- A drop is only kept on record for a fixed or soft claimer on this order's comeback list, or once the order's
  -- initials payment is due. Any other dropped claim is simply deleted.
  keep := (d.comeback_id is not null and exists (select 1 from public.comeback_roster k
                                                  where k.comeback_id = d.comeback_id and k.joiner_id = a.j_id))
          or (g.payment_deadline is not null and now() > public.drop_due_at(g.payment_deadline, g.payment_deadline_time));

  -- A fixed claimer can drop each of their fixed members from up to 3 of the comeback's orders, separately per
  -- member (HJ from 3 orders and SH from 3 orders). Soft claims have no drop limit.
  if c.source = 'fixed' and d.comeback_id is not null then
    select count(distinct x.group_order_id) into n_drops from public.claims x
      join public.group_orders xg on xg.id = x.group_order_id
      join public.drops xd on xd.id = xg.drop_id
     where x.joiner_id = a.j_id and x.status = 'dropped' and not x.switched and x.source = 'fixed'
       and xd.comeback_id = d.comeback_id
       and string_to_array(x.member_code, '/') && string_to_array(c.member_code, '/')
       and x.group_order_id <> c.group_order_id;
    if n_drops >= 3 then return jsonb_build_object('error', 'drop_limit'); end if;
  end if;

  if keep then
    update public.claims set status = 'dropped' where id = p_claim;
  else
    delete from public.claims where id = p_claim;
  end if;
  return jsonb_build_object('ok', true);
end $$;
