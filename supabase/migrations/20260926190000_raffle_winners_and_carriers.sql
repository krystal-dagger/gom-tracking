-- Raffle winners are picked from the order's joiners. "winner" (text) stays and holds the winner's handle, so
-- older raffles with a typed-in winner still show.
ALTER TABLE "public"."raffles" ADD COLUMN IF NOT EXISTS "winner_joiner_id" "uuid";
ALTER TABLE "public"."raffles" DROP CONSTRAINT IF EXISTS "raffles_winner_joiner_id_fkey";
ALTER TABLE "public"."raffles" ADD CONSTRAINT "raffles_winner_joiner_id_fkey"
    FOREIGN KEY ("winner_joiner_id") REFERENCES "public"."joiners"("id") ON DELETE SET NULL;

-- Tracked shipping records its carrier (the site fills in USPS).
ALTER TABLE "public"."participants" ADD COLUMN IF NOT EXISTS "carrier" "text";
