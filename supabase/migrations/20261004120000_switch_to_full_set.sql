-- Fixed and soft claimers can switch to OT8 (OT4 on unit orders) on a comeback order and back again:
--  - joiner_switch_full replaces their fixed/soft claims on the order with one OT8/OT4 claim. The claims it replaces
--    are kept as dropped with switched = true (so they don't count as drops), and the new OT8/OT4 has switched = true.
--  - dropping that OT8/OT4 (joiner_unclaim) puts the switched claims back where they were in line.
--  - fixed claimers can drop their fixed claims themselves now, up to 3 orders per member per comeback.

alter table public.claims add column if not exists switched boolean not null default false;

CREATE OR REPLACE FUNCTION "public"."_switch_back"("p_order" "uuid", "p_joiner" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
begin
  delete from public.claims
   where group_order_id = p_order and joiner_id = p_joiner and switched and status = 'filled';
  -- a member they've claimed again as a fixed/soft claim in the meantime keeps that claim instead
  delete from public.claims x
   where x.group_order_id = p_order and x.joiner_id = p_joiner and x.switched and x.status = 'dropped'
     and exists (select 1 from public.claims y
                  where y.group_order_id = p_order and y.joiner_id = p_joiner and y.status = 'filled'
                    and y.member_code = x.member_code and y.source in ('fixed', 'soft'));
  update public.claims set status = 'filled', switched = false
   where group_order_id = p_order and joiner_id = p_joiner and switched and status = 'dropped';
end $$;
ALTER FUNCTION "public"."_switch_back"("p_order" "uuid", "p_joiner" "uuid") OWNER TO "postgres";
REVOKE ALL ON FUNCTION "public"."_switch_back"("p_order" "uuid", "p_joiner" "uuid") FROM PUBLIC;
REVOKE ALL ON FUNCTION "public"."_switch_back"("p_order" "uuid", "p_joiner" "uuid") FROM "anon", "authenticated";

CREATE OR REPLACE FUNCTION "public"."joiner_switch_full"("p_handle" "text", "p_pin" "text", "p_order" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  a  record;
  g  public.group_orders%rowtype;
  d  public.drops%rowtype;
  full_code text;
  nrows int;
  host boolean;
  n int;
begin
  select * into a from public._joiner_auth(p_handle, p_pin);
  if a.err is not null then return jsonb_build_object('error', a.err); end if;

  select * into g from public.group_orders where id = p_order;
  if not found or g.status <> 'Claims Open' then return jsonb_build_object('error', 'closed'); end if;
  select * into d from public.drops where id = g.drop_id;
  if d.deadline is not null and now() > public.drop_due_at(d.deadline, d.deadline_time) then
    return jsonb_build_object('error', 'deadline');
  end if;
  if d.type = 'Merch' then return jsonb_build_object('error', 'no_spots'); end if;
  if g.price_per_pc is null then return jsonb_build_object('error', 'no_price'); end if;
  full_code := case when d.solo_unit = 'Unit' then 'OT4' else 'OT8' end;
  nrows := case when d.solo_unit = 'Unit' then 4 else 8 end;

  if exists (select 1 from public.claims x where x.group_order_id = p_order and x.joiner_id = a.j_id
               and x.switched and x.status = 'filled') then
    return jsonb_build_object('error', 'already_switched');
  end if;

  update public.claims set status = 'dropped', switched = true
   where group_order_id = p_order and joiner_id = a.j_id and status = 'filled' and source in ('fixed', 'soft');
  get diagnostics n = row_count;
  if n = 0 then return jsonb_build_object('error', 'no_spots'); end if;

  select coalesce(j.is_host, false) into host from public.joiners j where j.id = a.j_id;
  insert into public.claims (group_order_id, joiner_id, member_code, items, price, status, source, roster_pos, created_at, switched)
  values (p_order, a.j_id, full_code, nrows, coalesce(g.ot8_price, g.price_per_pc * nrows), 'filled',
          case when host then 'gom' else 'extra' end, null, clock_timestamp(), true);
  perform public._auto_assign_bonus(p_order, a.j_id);
  return jsonb_build_object('ok', true, 'replaced', n);
end $$;
ALTER FUNCTION "public"."joiner_switch_full"("p_handle" "text", "p_pin" "text", "p_order" "uuid") OWNER TO "postgres";
REVOKE ALL ON FUNCTION "public"."joiner_switch_full"("p_handle" "text", "p_pin" "text", "p_order" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."joiner_switch_full"("p_handle" "text", "p_pin" "text", "p_order" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."joiner_switch_full"("p_handle" "text", "p_pin" "text", "p_order" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."joiner_switch_full"("p_handle" "text", "p_pin" "text", "p_order" "uuid") TO "service_role";

-- Fixed claimers can drop their fixed claims (within the per-member limit), and dropping a switched-to OT8/OT4
-- switches back. Drops that were really switches don't count.
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

  -- A fixed or soft claimer can drop each of their members from up to 3 of the comeback's orders, separately per
  -- member and per claim type (fixed HJ from 3 orders and fixed SH from 3 orders).
  if c.source in ('fixed', 'soft') and d.comeback_id is not null then
    select count(distinct x.group_order_id) into n_drops from public.claims x
      join public.group_orders xg on xg.id = x.group_order_id
      join public.drops xd on xd.id = xg.drop_id
     where x.joiner_id = a.j_id and x.status = 'dropped' and not x.switched and x.source = c.source
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

