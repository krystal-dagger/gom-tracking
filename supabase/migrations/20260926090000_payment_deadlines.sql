-- Each kind of payment gets its own deadline (a date, plus an optional time saved as "HH:MM Area/City").
--   Initials and DOMs: set on the group order. group_orders.payment_deadline is now the initials deadline.
--   EMS and customs:   set on the kaddy box; every group order in that box uses them.

ALTER TABLE "public"."group_orders"
    ADD COLUMN IF NOT EXISTS "payment_deadline_time" "text",
    ADD COLUMN IF NOT EXISTS "doms_deadline" "date",
    ADD COLUMN IF NOT EXISTS "doms_deadline_time" "text";

ALTER TABLE "public"."shipments"
    ADD COLUMN IF NOT EXISTS "ems_deadline" "date",
    ADD COLUMN IF NOT EXISTS "ems_deadline_time" "text",
    ADD COLUMN IF NOT EXISTS "customs_deadline" "date",
    ADD COLUMN IF NOT EXISTS "customs_deadline_time" "text";

-- Joiners read kaddy boxes through this view, so the new deadlines go on the end of it (existing grants stay).
CREATE OR REPLACE VIEW "public"."public_shipments" AS
 SELECT "id",
    "number",
    "kaddy",
    "status",
    "paid_on",
    "shipped_on",
    "delivered_on",
    "ems_deadline",
    "ems_deadline_time",
    "customs_deadline",
    "customs_deadline_time"
   FROM "public"."shipments";
