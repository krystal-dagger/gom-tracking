-- For a group order whose drop has a fancall or fansign: what the entry is.
--   raffle   = raffled among the order's joiners
--   personal = the GOM's own attempt
--   hosting  = hosted for a joiner, named in event_for_joiner
ALTER TABLE "public"."group_orders"
    ADD COLUMN IF NOT EXISTS "event_mode" "text",
    ADD COLUMN IF NOT EXISTS "event_for_joiner" "uuid";

ALTER TABLE "public"."group_orders" DROP CONSTRAINT IF EXISTS "group_orders_event_mode_check";
ALTER TABLE "public"."group_orders" ADD CONSTRAINT "group_orders_event_mode_check"
    CHECK ("event_mode" IS NULL OR "event_mode" = ANY (ARRAY['raffle'::"text", 'personal'::"text", 'hosting'::"text"]));

ALTER TABLE "public"."group_orders" DROP CONSTRAINT IF EXISTS "group_orders_event_for_joiner_fkey";
ALTER TABLE "public"."group_orders" ADD CONSTRAINT "group_orders_event_for_joiner_fkey"
    FOREIGN KEY ("event_for_joiner") REFERENCES "public"."joiners"("id") ON DELETE SET NULL;
