-- 1. Raffles: everyone is entered unless they opt out. Answers are no longer required before claiming; a joiner
--    with no answer for a raffle counts as entered. (Claiming still saves any opt-outs ticked on the claim form.)
CREATE OR REPLACE FUNCTION "public"."_raffle_answers"("p_order" "uuid", "p_joiner" "uuid", "p_raffles" "jsonb", "p_write" boolean) RETURNS "text"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
declare
  r record;
  v jsonb;
  had boolean;
  late boolean;
begin
  if not p_write then return null; end if;
  select g.payment_deadline is not null and now() > public.drop_due_at(g.payment_deadline, g.payment_deadline_time)
    into late from public.group_orders g where g.id = p_order;
  for r in select x.id, x.winner_joiner_id, x.winner from public.raffles x where x.group_order_id = p_order loop
    v := case when jsonb_typeof(p_raffles) = 'object' then p_raffles -> (r.id::text) else null end;
    had := exists (select 1 from public.raffle_entries e where e.raffle_id = r.id and e.joiner_id = p_joiner);
    if v is not null and jsonb_typeof(v) = 'boolean' and r.winner_joiner_id is null and r.winner is null and not (had and coalesce(late, false)) then
      insert into public.raffle_entries (raffle_id, joiner_id, entered, updated_at) values (r.id, p_joiner, v::text::boolean, now())
      on conflict (raffle_id, joiner_id) do update set entered = excluded.entered, updated_at = now();
    end if;
  end loop;
  return null;
end $$;


-- 2. Dropping a claim: only kept as "dropped" when it matters (see joiner_unclaim), otherwise deleted; fixed
--    claimers can drop each fixed member at most 3 times per comeback.
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
  if c.source = 'fixed' and not exists (
       select 1 from public.claims x
        where x.group_order_id = c.group_order_id and x.joiner_id = a.j_id
          and x.member_code = full_code and x.status = 'filled') then
    return jsonb_build_object('error', 'fixed');
  end if;

  -- A drop is only kept on record for a fixed or soft claimer on this order's comeback list, or once the order's
  -- initials payment is due. Any other dropped claim is simply deleted.
  keep := (d.comeback_id is not null and exists (select 1 from public.comeback_roster k
                                                  where k.comeback_id = d.comeback_id and k.joiner_id = a.j_id))
          or (g.payment_deadline is not null and now() > public.drop_due_at(g.payment_deadline, g.payment_deadline_time));

  -- A fixed claimer can drop each of their fixed members at most 3 times across the comeback's orders.
  if c.source = 'fixed' then
    select count(*) into n_drops from public.claims x
      join public.group_orders xg on xg.id = x.group_order_id
      join public.drops xd on xd.id = xg.drop_id
     where x.joiner_id = a.j_id and x.status = 'dropped' and x.source = 'fixed'
       and xd.comeback_id is not distinct from d.comeback_id
       and string_to_array(x.member_code, '/') && string_to_array(c.member_code, '/');
    if n_drops >= 3 then return jsonb_build_object('error', 'fixed_limit'); end if;
  end if;

  if keep then
    update public.claims set status = 'dropped' where id = p_claim;
  else
    delete from public.claims where id = p_claim;
  end if;
  return jsonb_build_object('ok', true);
end $$;
