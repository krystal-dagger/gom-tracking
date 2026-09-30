-- Bonus items where the joiner picks the type: each type can only be picked once per full set of types the order
-- has earned. With "claim 3, get 1" and 4 types, one full set (one of each type) takes 12 claimed items, two take
-- 24, and so on, so each type opens up one more pick every 12 items.

-- How many of each type have been picked so far (counts only), so the site can show what's still available.
CREATE OR REPLACE VIEW "public"."public_bonus_type_counts" AS
 SELECT "bonus_item_id",
    "type",
    ("count"(*))::integer AS "picked"
   FROM "public"."bonus_claims"
  WHERE (("status" = 'filled'::"text") AND ("type" IS NOT NULL))
  GROUP BY "bonus_item_id", "type";

ALTER VIEW "public"."public_bonus_type_counts" OWNER TO "postgres";
GRANT SELECT ON TABLE "public"."public_bonus_type_counts" TO "anon";
GRANT SELECT ON TABLE "public"."public_bonus_type_counts" TO "authenticated";
GRANT SELECT ON TABLE "public"."public_bonus_type_counts" TO "service_role";


CREATE OR REPLACE FUNCTION "public"."joiner_pick_bonus_type"("p_handle" "text", "p_pin" "text", "p_bonus_claim_id" "uuid", "p_type" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  a    record;
  bc   public.bonus_claims%rowtype;
  bi   public.bonus_items%rowtype;
  gi   int;
  sets int;
  used int;
begin
  select * into a from public._joiner_auth(p_handle, p_pin);
  if a.err is not null then return jsonb_build_object('error', a.err); end if;

  select * into bc from public.bonus_claims where id = p_bonus_claim_id and joiner_id = a.j_id and status = 'filled';
  if not found then return jsonb_build_object('error', 'not_found'); end if;
  if bc.type is not null then return jsonb_build_object('error', 'already_picked'); end if;

  -- lock the bonus item so two joiners can't both take the last one of a type
  select * into bi from public.bonus_items where id = bc.bonus_item_id for update;
  if not found or not bi.joiner_picks then return jsonb_build_object('error', 'not_allowed'); end if;
  if p_type is null or not (bi.type_names ? p_type) then return jsonb_build_object('error', 'bad_type'); end if;

  select coalesce(sum(items), 0) into gi from public.claims where group_order_id = bc.group_order_id and status = 'filled';
  sets := floor(floor(gi / bi.claims_needed) / greatest(bi.type_count, 1));
  select count(*) into used from public.bonus_claims
   where bonus_item_id = bi.id and status = 'filled' and type = p_type;
  if used >= sets then return jsonb_build_object('error', 'type_full', 'detail', sets); end if;

  update public.bonus_claims set type = p_type where id = p_bonus_claim_id;
  return jsonb_build_object('ok', true);
end $$;
