-- 1. Comebacks have one limit: the most spots (fixed and soft together) on each member, "max sets". Existing
--    comebacks start with their old fixed + soft spots per member. fixed_slots/soft_slots are no longer used.
ALTER TABLE "public"."comebacks" ADD COLUMN IF NOT EXISTS "max_sets" integer;
UPDATE "public"."comebacks" SET "max_sets" = "fixed_slots" + "soft_slots" WHERE "max_sets" IS NULL;
ALTER TABLE "public"."comebacks" ALTER COLUMN "max_sets" SET DEFAULT 7;
ALTER TABLE "public"."comebacks" ALTER COLUMN "max_sets" SET NOT NULL;
ALTER TABLE "public"."comebacks" DROP CONSTRAINT IF EXISTS "comebacks_max_sets_check";
ALTER TABLE "public"."comebacks" ADD CONSTRAINT "comebacks_max_sets_check" CHECK ("max_sets" >= 1);


-- 2. Fixed claimers can drop up to 3 orders per comeback (counted per order, not per member).
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

  -- A fixed claimer can drop up to 3 of the comeback's orders. Dropping another fixed member on an order they
  -- already dropped from doesn't use up another one.
  if c.source = 'fixed' then
    select count(distinct x.group_order_id) into n_drops from public.claims x
      join public.group_orders xg on xg.id = x.group_order_id
      join public.drops xd on xd.id = xg.drop_id
     where x.joiner_id = a.j_id and x.status = 'dropped' and x.source = 'fixed'
       and xd.comeback_id is not distinct from d.comeback_id
       and x.group_order_id <> c.group_order_id;
    if n_drops >= 3 then return jsonb_build_object('error', 'fixed_limit'); end if;
  end if;

  if keep then
    update public.claims set status = 'dropped' where id = p_claim;
  else
    delete from public.claims where id = p_claim;
  end if;
  return jsonb_build_object('ok', true);
end $$;
