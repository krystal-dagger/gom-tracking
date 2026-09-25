-- 1. The "Shipped to Joiners" group order status is now "Completed". An order can be marked completed before every
--    joiner's items have gone out (some wait for other orders to arrive so they ship together).
ALTER TABLE "public"."group_orders" DROP CONSTRAINT IF EXISTS "group_orders_status_check";
UPDATE "public"."group_orders" SET "status" = 'Completed' WHERE "status" = 'Shipped to Joiners';
ALTER TABLE "public"."group_orders" ADD CONSTRAINT "group_orders_status_check"
    CHECK (("status" = ANY (ARRAY['Claims Open'::"text", 'Claims Closed'::"text", 'Ordered'::"text", 'At Kaddy'::"text",
                                  'Shipping to Host'::"text", 'On Hand'::"text", 'Completed'::"text", 'Cancelled'::"text"])));


-- 2. Payments remember what they paid for: one entry per group order, with the amount going to each part
--    (initials, ems, customs, doms, other), like [{"group_order_id": "...", "parts": {"initials": 12, "ems": 5.25}}].
ALTER TABLE "public"."payments" ADD COLUMN IF NOT EXISTS "breakdown" "jsonb";

DROP FUNCTION IF EXISTS "public"."joiner_submit_payment"("p_handle" "text", "p_pin" "text", "p_amount" numeric, "p_method" "text", "p_note" "text", "p_screenshot_path" "text", "p_order_ids" "uuid"[]);

CREATE OR REPLACE FUNCTION "public"."joiner_submit_payment"("p_handle" "text", "p_pin" "text", "p_amount" numeric, "p_method" "text", "p_note" "text", "p_screenshot_path" "text", "p_order_ids" "uuid"[], "p_breakdown" "jsonb" DEFAULT NULL) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  a record;
  bd jsonb;
begin
  select * into a from public._joiner_auth(p_handle, p_pin);
  if a.err is not null then return jsonb_build_object('error', a.err); end if;
  if p_amount is null or p_amount <= 0 then return jsonb_build_object('error', 'bad_amount'); end if;
  if p_method not in ('paypal','venmo','wise') then return jsonb_build_object('error', 'bad_method'); end if;

  -- keep only a sane-looking breakdown for orders this payment is for; anything else is dropped, not an error
  select jsonb_agg(jsonb_build_object('group_order_id', e->>'group_order_id', 'parts', e->'parts'))
    into bd
    from jsonb_array_elements(case when jsonb_typeof(p_breakdown) = 'array' and jsonb_array_length(p_breakdown) <= 50
                                   then p_breakdown else '[]'::jsonb end) e
   where jsonb_typeof(e->'parts') = 'object'
     and (e->>'group_order_id') = any (select x::text from unnest(coalesce(p_order_ids, '{}'::uuid[])) x);

  insert into public.payments (joiner_id, amount, method, paid_on, note, status, screenshot_path, order_ids, breakdown)
  values (a.j_id, p_amount, p_method, current_date, p_note, 'pending', p_screenshot_path, p_order_ids, bd);

  return jsonb_build_object('ok', true);
end $$;


ALTER FUNCTION "public"."joiner_submit_payment"("p_handle" "text", "p_pin" "text", "p_amount" numeric, "p_method" "text", "p_note" "text", "p_screenshot_path" "text", "p_order_ids" "uuid"[], "p_breakdown" "jsonb") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "public"."joiner_submit_payment"("p_handle" "text", "p_pin" "text", "p_amount" numeric, "p_method" "text", "p_note" "text", "p_screenshot_path" "text", "p_order_ids" "uuid"[], "p_breakdown" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."joiner_submit_payment"("p_handle" "text", "p_pin" "text", "p_amount" numeric, "p_method" "text", "p_note" "text", "p_screenshot_path" "text", "p_order_ids" "uuid"[], "p_breakdown" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."joiner_submit_payment"("p_handle" "text", "p_pin" "text", "p_amount" numeric, "p_method" "text", "p_note" "text", "p_screenshot_path" "text", "p_order_ids" "uuid"[], "p_breakdown" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."joiner_submit_payment"("p_handle" "text", "p_pin" "text", "p_amount" numeric, "p_method" "text", "p_note" "text", "p_screenshot_path" "text", "p_order_ids" "uuid"[], "p_breakdown" "jsonb") TO "service_role";
