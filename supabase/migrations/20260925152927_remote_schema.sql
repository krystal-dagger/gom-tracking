


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."_auto_assign_bonus"("p_order" "uuid", "p_joiner" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  bi record;
  personal_items int;
  personal_earned int;
  already int;
  global_items int;
  global_earned int;
  global_assigned int;
  to_add int;
  i int;
begin
  for bi in select * from public.bonus_items where group_order_id = p_order loop
    select coalesce(sum(items), 0) into personal_items from public.claims
      where group_order_id = p_order and joiner_id = p_joiner and status = 'filled';
    personal_earned := floor(personal_items / bi.claims_needed);

    select count(*) into already from public.bonus_claims
      where bonus_item_id = bi.id and joiner_id = p_joiner and status = 'filled';

    if personal_earned > already then
      select coalesce(sum(items), 0) into global_items from public.claims
        where group_order_id = p_order and status = 'filled';
      global_earned := floor(global_items / bi.claims_needed);
      select count(*) into global_assigned from public.bonus_claims where bonus_item_id = bi.id and status = 'filled';

      to_add := least(personal_earned - already, greatest(0, global_earned - global_assigned));
      i := 0;
      while i < to_add loop
        insert into public.bonus_claims (group_order_id, bonus_item_id, joiner_id, status)
        values (p_order, bi.id, p_joiner, 'filled');
        i := i + 1;
      end loop;
    end if;
  end loop;
end $$;


ALTER FUNCTION "public"."_auto_assign_bonus"("p_order" "uuid", "p_joiner" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_joiner_auth"("p_handle" "text", "p_pin" "text", OUT "j_id" "uuid", OUT "err" "text") RETURNS "record"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  h  text := lower(regexp_replace(trim(coalesce(p_handle, '')), '^@', ''));
  la record;
  ja record;
  ok boolean;
begin
  select * into la from public.login_attempts where handle = h;
  if la.locked_until is not null and la.locked_until > now() then
    err := 'locked'; return;
  end if;
  select ja2.joiner_id, j.pin_hash into ja from public.joiner_accounts ja2
    join public.joiners j on j.id = ja2.joiner_id where ja2.handle = h;
  if ja.pin_hash is null then
    insert into public.login_attempts (handle, failures) values (h, coalesce(la.failures, 0) + 1)
      on conflict (handle) do update set failures = public.login_attempts.failures + 1,
        locked_until = case when public.login_attempts.failures + 1 >= 8 then now() + interval '15 minutes' else null end;
    err := 'invalid'; return;
  end if;
  ok := extensions.crypt(p_pin, ja.pin_hash) = ja.pin_hash;
  if not ok then
    insert into public.login_attempts (handle, failures) values (h, coalesce(la.failures, 0) + 1)
      on conflict (handle) do update set failures = public.login_attempts.failures + 1,
        locked_until = case when public.login_attempts.failures + 1 >= 8 then now() + interval '15 minutes' else null end;
    err := 'invalid'; return;
  end if;
  delete from public.login_attempts where handle = h;
  j_id := ja.joiner_id;
end $$;


ALTER FUNCTION "public"."_joiner_auth"("p_handle" "text", "p_pin" "text", OUT "j_id" "uuid", OUT "err" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_recompute_bonus"("p_order" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  jid uuid;
begin
  if not public.is_admin() then raise exception 'not authorized'; end if;
  for jid in select distinct joiner_id from public.claims where group_order_id = p_order and status = 'filled' loop
    perform public._auto_assign_bonus(p_order, jid);
  end loop;
end $$;


ALTER FUNCTION "public"."admin_recompute_bonus"("p_order" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_set_pin"("p_joiner_id" "uuid", "p_pin" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
begin
  if not public.is_admin() then
    raise exception 'Only the host can set PINs';
  end if;
  if length(coalesce(p_pin, '')) < 4 then
    raise exception 'PIN must be at least 4 characters';
  end if;
  update public.joiners
     set pin_hash = extensions.crypt(p_pin, extensions.gen_salt('bf'))
   where id = p_joiner_id;
  delete from public.login_attempts
   where handle in (select handle from public.joiner_accounts where joiner_id = p_joiner_id);
end $$;


ALTER FUNCTION "public"."admin_set_pin"("p_joiner_id" "uuid", "p_pin" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ensure_participant"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  insert into public.participants (group_order_id, joiner_id)
  values (new.group_order_id, new.joiner_id)
  on conflict do nothing;
  return new;
end $$;


ALTER FUNCTION "public"."ensure_participant"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;


ALTER FUNCTION "public"."is_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."joiner_claim"("p_handle" "text", "p_pin" "text", "p_order" "uuid", "p_members" "text"[]) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  a       record;
  g       public.group_orders%rowtype;
  d       public.drops%rowtype;
  merch   boolean;
  unit    boolean;
  rws     text[];
  nrows   int;
  codes   text[];
  c       text;
  item    text;      -- the merch item name a code belongs to (itself, or the part before "::")
  pr      numeric;
  it      int;
  n       int := 0;
  host    boolean;
  onlist  boolean;
  stand   text;
  src     text;
  full_code text;
  cnt     int;
begin
  select * into a from public._joiner_auth(p_handle, p_pin);
  if a.err is not null then return jsonb_build_object('error', a.err); end if;

  select * into g from public.group_orders where id = p_order;
  if not found or g.status <> 'Claims Open' then return jsonb_build_object('error', 'closed'); end if;
  select * into d from public.drops where id = g.drop_id;
  -- the deadline lives on the drop, and is in KST
  if d.deadline is not null and (now() at time zone 'Asia/Seoul')::date > d.deadline then
    return jsonb_build_object('error', 'deadline');
  end if;

  merch := d.type = 'Merch';
  unit  := not merch and d.solo_unit = 'Unit';
  if merch then
    select coalesce(array_agg(row_code order by mi.position, mi.name, member_ord), '{}') into rws
    from (
      select mi.id, mi.name, mi.position, mi.member_options,
             case when mi.member_options then m.code else null end as member_ord,
             case when mi.member_options then mi.name || '::' || m.code else mi.name end as row_code
      from public.merch_items mi
      join public.go_merch_items gmi on gmi.merch_item_id = mi.id and gmi.group_order_id = p_order
      left join lateral unnest(array['HJ','SH','YH','YS','SN','MG','WY','JH']) as m(code) on mi.member_options
    ) x(id, name, position, member_options, member_ord, row_code)
    join public.merch_items mi on mi.id = x.id;
  else
    rws := case when unit then array['HJ/SH','YH/MG','YS/WY','SN/JH']
                else array['HJ','SH','YH','YS','SN','MG','WY','JH'] end;
  end if;
  nrows := array_length(rws, 1);
  full_code := case when merch then null when unit then 'OT4' else 'OT8' end;

  if merch then
    if coalesce(array_length(rws, 1), 0) = 0 then return jsonb_build_object('error', 'no_price'); end if;
  elsif g.price_per_pc is null then
    return jsonb_build_object('error', 'no_price');
  end if;

  if merch then
    select coalesce(array_agg(trim(x)), '{}') into codes
    from unnest(coalesce(p_members, '{}'::text[])) x where trim(x) <> '';
  else
    select coalesce(array_agg(upper(trim(x))), '{}') into codes
    from unnest(coalesce(p_members, '{}'::text[])) x where trim(x) <> '';
  end if;
  if coalesce(array_length(codes, 1), 0) = 0 then return jsonb_build_object('error', 'nothing'); end if;
  if array_length(codes, 1) > 40 then return jsonb_build_object('error', 'too_many'); end if;
  foreach c in array codes loop
    if not (coalesce(c = full_code, false) or c = any(rws)) then
      return jsonb_build_object('error', 'bad_member', 'detail', c);
    end if;
  end loop;

  -- Max # of sets (PC) / max # to purchase (merch): a code can't be claimed past its own cap, counting
  -- claims already on this order (a claim's "set number" is its position in its own code's queue).
  foreach c in array codes loop
    if merch then
      item := split_part(c, '::', 1);
      select gmi.max_purchase into pr from public.go_merch_items gmi join public.merch_items mi on mi.id = gmi.merch_item_id
        where gmi.group_order_id = p_order and mi.name = item;
      if pr is not null then
        select count(*) into cnt from public.claims x
          where x.group_order_id = p_order and x.status = 'filled'
            and (x.member_code = item or x.member_code like item || '::%');
        if cnt >= pr then return jsonb_build_object('error', 'sold_out', 'detail', item); end if;
      end if;
    elsif g.max_sets is not null and c <> full_code then
      select count(*) into cnt from public.claims x where x.group_order_id = p_order and x.member_code = c and x.status = 'filled';
      if cnt >= g.max_sets then return jsonb_build_object('error', 'sold_out', 'detail', c); end if;
    end if;
  end loop;

  select coalesce(j.is_host, false) into host from public.joiners j where j.id = a.j_id;
  onlist := d.comeback_id is not null and g.roster_required
            and exists (select 1 from public.comeback_roster k
                        where k.comeback_id = d.comeback_id and k.joiner_id = a.j_id);

  foreach c in array codes loop
    src := 'joiner';
    if host then
      src := 'gom';
    elsif onlist then
      src := 'extra';
      if coalesce(c <> full_code, true) and not merch then
        select k.tier into stand from public.comeback_roster k
         where k.comeback_id = d.comeback_id and k.joiner_id = a.j_id
           and k.member_code = any (string_to_array(c, '/'))
         order by (k.tier = 'fixed') desc limit 1;
        if stand is not null and not exists (
             select 1 from public.claims x
              where x.group_order_id = p_order and x.joiner_id = a.j_id and x.member_code = c
                and x.status = 'filled' and x.source in ('fixed','soft','gom')) then
          src := stand;
        end if;
      end if;
    end if;

    if merch then
      item := split_part(c, '::', 1);
      select gmi.price into pr from public.go_merch_items gmi join public.merch_items mi on mi.id = gmi.merch_item_id
        where gmi.group_order_id = p_order and mi.name = item;
      it := 1;
    else
      pr := case when c = full_code then coalesce(g.ot8_price, g.price_per_pc * nrows) else g.price_per_pc end;
      it := case when c = full_code then nrows else 1 end;
    end if;
    insert into public.claims (group_order_id, joiner_id, member_code, items, price, status, source, roster_pos, created_at)
    values (p_order, a.j_id, c, it, pr, 'filled', src, null, clock_timestamp());
    n := n + 1;
  end loop;

  if not merch and n > 0 then
    perform public._auto_assign_bonus(p_order, a.j_id);
  end if;

  return jsonb_build_object('ok', true, 'added', n);
end $$;


ALTER FUNCTION "public"."joiner_claim"("p_handle" "text", "p_pin" "text", "p_order" "uuid", "p_members" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."joiner_dashboard"("p_handle" "text", "p_pin" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  a public.joiners%rowtype;
  r record;
begin
  select * into r from public._joiner_auth(p_handle, p_pin);
  if r.err is not null then
    return jsonb_build_object('error', r.err);
  end if;
  select * into a from public.joiners where id = r.j_id;

  return jsonb_build_object(
    'joiner',  jsonb_build_object('id', a.id, 'name', a.name, 'emoji', a.emoji, 'is_host', a.is_host),
    'handles', (select coalesce(jsonb_agg(handle order by handle), '[]'::jsonb)
                from public.joiner_accounts where joiner_id = a.id),
    'claims',  (select coalesce(jsonb_agg(to_jsonb(c) - 'joiner_id' - 'created_at'), '[]'::jsonb)
                from public.claims c where c.joiner_id = a.id),
    'charges', (select coalesce(jsonb_agg(to_jsonb(c) - 'joiner_id' - 'created_at'), '[]'::jsonb)
                from public.charges c where c.joiner_id = a.id),
    'payments',(select coalesce(jsonb_agg(to_jsonb(p) - 'joiner_id' - 'created_at' order by p.paid_on), '[]'::jsonb)
                from public.payments p where p.joiner_id = a.id),
    'participation', (select coalesce(jsonb_agg(to_jsonb(x) - 'joiner_id'), '[]'::jsonb)
                from public.participants x where x.joiner_id = a.id),
    'roster',  (select coalesce(jsonb_agg(jsonb_build_object(
                    'comeback_id', k.comeback_id, 'tier', k.tier, 'member_code', k.member_code,
                    'position', k.position, 'waitlist', k.waitlist) order by k.tier, k.position), '[]'::jsonb)
                from public.comeback_roster k where k.joiner_id = a.id),
    'emojis',  (select coalesce(jsonb_agg(jsonb_build_object('comeback_id', e.comeback_id, 'emoji', e.emoji)), '[]'::jsonb)
                from public.comeback_emojis e where e.joiner_id = a.id),
    'bonus_claims', (select coalesce(jsonb_agg(to_jsonb(b) - 'joiner_id' - 'created_at'), '[]'::jsonb)
                from public.bonus_claims b where b.joiner_id = a.id and b.status = 'filled')
  );
end $$;


ALTER FUNCTION "public"."joiner_dashboard"("p_handle" "text", "p_pin" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."joiner_pick_bonus_type"("p_handle" "text", "p_pin" "text", "p_bonus_claim_id" "uuid", "p_type" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  a  record;
  bc public.bonus_claims%rowtype;
  bi public.bonus_items%rowtype;
begin
  select * into a from public._joiner_auth(p_handle, p_pin);
  if a.err is not null then return jsonb_build_object('error', a.err); end if;

  select * into bc from public.bonus_claims where id = p_bonus_claim_id and joiner_id = a.j_id and status = 'filled';
  if not found then return jsonb_build_object('error', 'not_found'); end if;
  if bc.type is not null then return jsonb_build_object('error', 'already_picked'); end if;

  select * into bi from public.bonus_items where id = bc.bonus_item_id;
  if not found or not bi.joiner_picks then return jsonb_build_object('error', 'not_allowed'); end if;
  if p_type is null or not (bi.type_names ? p_type) then return jsonb_build_object('error', 'bad_type'); end if;

  update public.bonus_claims set type = p_type where id = p_bonus_claim_id;
  return jsonb_build_object('ok', true);
end $$;


ALTER FUNCTION "public"."joiner_pick_bonus_type"("p_handle" "text", "p_pin" "text", "p_bonus_claim_id" "uuid", "p_type" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."joiner_submit_payment"("p_handle" "text", "p_pin" "text", "p_amount" numeric, "p_method" "text", "p_note" "text", "p_screenshot_path" "text", "p_order_ids" "uuid"[]) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  a record;
begin
  select * into a from public._joiner_auth(p_handle, p_pin);
  if a.err is not null then return jsonb_build_object('error', a.err); end if;
  if p_amount is null or p_amount <= 0 then return jsonb_build_object('error', 'bad_amount'); end if;
  if p_method not in ('paypal','venmo','wise') then return jsonb_build_object('error', 'bad_method'); end if;

  insert into public.payments (joiner_id, amount, method, paid_on, note, status, screenshot_path, order_ids)
  values (a.j_id, p_amount, p_method, current_date, p_note, 'pending', p_screenshot_path, p_order_ids);

  return jsonb_build_object('ok', true);
end $$;


ALTER FUNCTION "public"."joiner_submit_payment"("p_handle" "text", "p_pin" "text", "p_amount" numeric, "p_method" "text", "p_note" "text", "p_screenshot_path" "text", "p_order_ids" "uuid"[]) OWNER TO "postgres";


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
begin
  select * into a from public._joiner_auth(p_handle, p_pin);
  if a.err is not null then return jsonb_build_object('error', a.err); end if;

  select * into c from public.claims where id = p_claim and joiner_id = a.j_id;
  if not found or c.status <> 'filled' then return jsonb_build_object('error', 'not_found'); end if;
  select * into g from public.group_orders where id = c.group_order_id;
  select * into d from public.drops where id = g.drop_id;
  if g.status <> 'Claims Open'
     or (d.deadline is not null and (now() at time zone 'Asia/Seoul')::date > d.deadline) then
    return jsonb_build_object('error', 'closed');
  end if;
  full_code := case when d.type = 'Merch' then null when d.solo_unit = 'Unit' then 'OT4' else 'OT8' end;
  if c.source = 'fixed' and not exists (
       select 1 from public.claims x
        where x.group_order_id = c.group_order_id and x.joiner_id = a.j_id
          and x.member_code = full_code and x.status = 'filled') then
    return jsonb_build_object('error', 'fixed');
  end if;

  update public.claims set status = 'dropped' where id = p_claim;
  return jsonb_build_object('ok', true);
end $$;


ALTER FUNCTION "public"."joiner_unclaim"("p_handle" "text", "p_pin" "text", "p_claim" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_auto_enable"() RETURNS "event_trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog'
    AS $$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."rls_auto_enable"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."admins" (
    "user_id" "uuid" NOT NULL
);


ALTER TABLE "public"."admins" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bonus_claims" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "group_order_id" "uuid" NOT NULL,
    "bonus_item_id" "uuid" NOT NULL,
    "joiner_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'filled'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "type" "text",
    CONSTRAINT "bonus_claims_status_check" CHECK (("status" = ANY (ARRAY['filled'::"text", 'dropped'::"text"])))
);


ALTER TABLE "public"."bonus_claims" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bonus_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "group_order_id" "uuid" NOT NULL,
    "item_name" "text" NOT NULL,
    "claims_needed" integer NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "type_count" integer DEFAULT 1 NOT NULL,
    "type_names" "jsonb",
    "joiner_picks" boolean DEFAULT false NOT NULL,
    CONSTRAINT "bonus_items_claims_needed_check" CHECK (("claims_needed" >= 1)),
    CONSTRAINT "bonus_items_type_count_check" CHECK (("type_count" >= 1))
);


ALTER TABLE "public"."bonus_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."charges" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "joiner_id" "uuid" NOT NULL,
    "group_order_id" "uuid",
    "kind" "text" DEFAULT 'fee'::"text" NOT NULL,
    "label" "text" NOT NULL,
    "amount" numeric(8,2) NOT NULL,
    "due" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "charges_kind_check" CHECK (("kind" = ANY (ARRAY['ems'::"text", 'doms'::"text", 'customs'::"text", 'fee'::"text", 'other'::"text"])))
);


ALTER TABLE "public"."charges" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."claims" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "group_order_id" "uuid" NOT NULL,
    "joiner_id" "uuid" NOT NULL,
    "member_code" "text" NOT NULL,
    "items" integer DEFAULT 1 NOT NULL,
    "price" numeric(8,2) DEFAULT 0 NOT NULL,
    "status" "text" DEFAULT 'filled'::"text" NOT NULL,
    "source" "text" DEFAULT 'joiner'::"text" NOT NULL,
    "roster_pos" integer,
    "note" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "claims_source_check" CHECK (("source" = ANY (ARRAY['joiner'::"text", 'gom'::"text", 'fixed'::"text", 'soft'::"text", 'extra'::"text"]))),
    CONSTRAINT "claims_status_check" CHECK (("status" = ANY (ARRAY['filled'::"text", 'dropped'::"text"])))
);


ALTER TABLE "public"."claims" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."comeback_emojis" (
    "comeback_id" "uuid" NOT NULL,
    "joiner_id" "uuid" NOT NULL,
    "emoji" "text" NOT NULL
);


ALTER TABLE "public"."comeback_emojis" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."comeback_roster" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "comeback_id" "uuid" NOT NULL,
    "tier" "text" NOT NULL,
    "member_code" "text" NOT NULL,
    "position" integer NOT NULL,
    "waitlist" boolean DEFAULT false NOT NULL,
    "joiner_id" "uuid" NOT NULL,
    CONSTRAINT "comeback_roster_position_check" CHECK (("position" >= 1)),
    CONSTRAINT "comeback_roster_tier_check" CHECK (("tier" = ANY (ARRAY['fixed'::"text", 'soft'::"text"])))
);


ALTER TABLE "public"."comeback_roster" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."comebacks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "soft_min_orders" integer DEFAULT 6 NOT NULL,
    "fixed_slots" integer DEFAULT 2 NOT NULL,
    "soft_slots" integer DEFAULT 5 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "comebacks_fixed_slots_check" CHECK (("fixed_slots" >= 0)),
    CONSTRAINT "comebacks_soft_min_orders_check" CHECK (("soft_min_orders" >= 0)),
    CONSTRAINT "comebacks_soft_slots_check" CHECK (("soft_slots" >= 0))
);


ALTER TABLE "public"."comebacks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."drops" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text",
    "type" "text" DEFAULT 'PC'::"text" NOT NULL,
    "store" "text",
    "comeback_id" "uuid",
    "round" "text",
    "announced_on" "date",
    "status" "text" DEFAULT 'announced'::"text" NOT NULL,
    "images" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "deadline" "date",
    "deadline_time" "text",
    "event_type" "text" DEFAULT 'none'::"text" NOT NULL,
    "event_on" "date",
    "winners_on" "date",
    "winners_time" "text",
    "notes" "text",
    "album_type" "text",
    "pc_type" "text",
    "solo_unit" "text",
    "category" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "set_name" "text",
    CONSTRAINT "drops_album_type_check" CHECK (("album_type" = ANY (ARRAY['Regular'::"text", 'Digipack (Member)'::"text", 'Digipack (Unit)'::"text", 'POCA'::"text", 'Other'::"text"]))),
    CONSTRAINT "drops_event_type_check" CHECK (("event_type" = ANY (ARRAY['none'::"text", 'fancall'::"text", 'fansign'::"text", 'fancall & fansign'::"text"]))),
    CONSTRAINT "drops_images_is_array" CHECK (("jsonb_typeof"("images") = 'array'::"text")),
    CONSTRAINT "drops_pc_type_check" CHECK (("pc_type" = ANY (ARRAY['POB'::"text", 'LD'::"text", 'Higher Timepiece'::"text", 'Album'::"text", 'Other'::"text"]))),
    CONSTRAINT "drops_solo_unit_check" CHECK (("solo_unit" = ANY (ARRAY['Solo'::"text", 'Unit'::"text"]))),
    CONSTRAINT "drops_status_check" CHECK (("status" = ANY (ARRAY['announced'::"text", 'planned'::"text", 'go_open'::"text", 'skipped'::"text"]))),
    CONSTRAINT "drops_type_check" CHECK (("type" = ANY (ARRAY['PC'::"text", 'Merch'::"text"])))
);


ALTER TABLE "public"."drops" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."go_merch_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "group_order_id" "uuid" NOT NULL,
    "merch_item_id" "uuid" NOT NULL,
    "price" numeric(8,2) NOT NULL,
    "max_purchase" integer,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "go_merch_items_price_check" CHECK (("price" >= (0)::numeric))
);


ALTER TABLE "public"."go_merch_items" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."go_stats" AS
 SELECT "group_order_id",
    ("count"(DISTINCT "joiner_id"))::integer AS "joiners",
    (COALESCE("sum"("items") FILTER (WHERE ("status" = 'filled'::"text")), (0)::bigint))::integer AS "items"
   FROM "public"."claims"
  GROUP BY "group_order_id";


ALTER VIEW "public"."go_stats" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."group_orders" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text",
    "drop_id" "uuid" NOT NULL,
    "emoji" "text",
    "platform" "text" DEFAULT 'instagram'::"text" NOT NULL,
    "platform_link" "text",
    "kaddy" "text" DEFAULT 'None'::"text" NOT NULL,
    "status" "text" DEFAULT 'Claims Open'::"text" NOT NULL,
    "public_note" "text",
    "host_note" "text",
    "shipment_id" "uuid",
    "roster_required" boolean DEFAULT true NOT NULL,
    "min_members" integer DEFAULT 0 NOT NULL,
    "split_cost" boolean DEFAULT false NOT NULL,
    "sort_threshold" numeric(8,2),
    "number_of_raffles" integer DEFAULT 0 NOT NULL,
    "price_per_pc" numeric(8,2),
    "ot8_price" numeric(8,2),
    "max_sets" integer,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "payment_deadline" "date",
    CONSTRAINT "group_orders_kaddy_check" CHECK (("kaddy" = ANY (ARRAY['None'::"text", 'Kfriday'::"text", 'Paysable'::"text"]))),
    CONSTRAINT "group_orders_min_members_check" CHECK (("min_members" >= 0)),
    CONSTRAINT "group_orders_number_of_raffles_check" CHECK (("number_of_raffles" >= 0)),
    CONSTRAINT "group_orders_platform_check" CHECK (("platform" = ANY (ARRAY['instagram'::"text", 'threads'::"text"]))),
    CONSTRAINT "group_orders_status_check" CHECK (("status" = ANY (ARRAY['Claims Open'::"text", 'Claims Closed'::"text", 'Ordered'::"text", 'At Kaddy'::"text", 'Shipping to Host'::"text", 'On Hand'::"text", 'Shipped to Joiners'::"text", 'Cancelled'::"text"])))
);


ALTER TABLE "public"."group_orders" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."joiner_accounts" (
    "handle" "text" NOT NULL,
    "joiner_id" "uuid" NOT NULL,
    "platform" "text" DEFAULT 'instagram'::"text" NOT NULL
);


ALTER TABLE "public"."joiner_accounts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."joiners" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "emoji" "text",
    "pin_hash" "text",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "is_host" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."joiners" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."login_attempts" (
    "handle" "text" NOT NULL,
    "failures" integer DEFAULT 0 NOT NULL,
    "locked_until" timestamp with time zone
);


ALTER TABLE "public"."login_attempts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."merch_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "drop_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "member_options" boolean DEFAULT false NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "member_names" "jsonb"
);


ALTER TABLE "public"."merch_items" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."order_seats" AS
 SELECT "c"."id" AS "claim_id",
    "c"."group_order_id",
    "c"."member_code",
    "c"."items",
    "c"."source",
    "c"."roster_pos",
    "c"."created_at",
    COALESCE("ce"."emoji", "j"."emoji") AS "emoji"
   FROM (((("public"."claims" "c"
     JOIN "public"."joiners" "j" ON (("j"."id" = "c"."joiner_id")))
     JOIN "public"."group_orders" "g" ON (("g"."id" = "c"."group_order_id")))
     JOIN "public"."drops" "d" ON (("d"."id" = "g"."drop_id")))
     LEFT JOIN "public"."comeback_emojis" "ce" ON ((("ce"."joiner_id" = "c"."joiner_id") AND ("ce"."comeback_id" = "d"."comeback_id"))))
  WHERE ("c"."status" = 'filled'::"text");


ALTER VIEW "public"."order_seats" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."participants" (
    "group_order_id" "uuid" NOT NULL,
    "joiner_id" "uuid" NOT NULL,
    "shipping_type" "text",
    "shipped" boolean DEFAULT false NOT NULL,
    "tracking" "text",
    "note" "text"
);


ALTER TABLE "public"."participants" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "joiner_id" "uuid" NOT NULL,
    "group_order_id" "uuid",
    "amount" numeric(8,2) NOT NULL,
    "method" "text" DEFAULT 'paypal'::"text",
    "paid_on" "date" DEFAULT CURRENT_DATE NOT NULL,
    "note" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "status" "text" DEFAULT 'approved'::"text" NOT NULL,
    "screenshot_path" "text",
    "order_ids" "uuid"[],
    "host_note" "text",
    CONSTRAINT "payments_method_check" CHECK (("method" = ANY (ARRAY['paypal'::"text", 'venmo'::"text", 'wise'::"text", 'cash'::"text", 'other'::"text"]))),
    CONSTRAINT "payments_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'denied'::"text", 'refunded'::"text"])))
);


ALTER TABLE "public"."payments" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."public_joiners" AS
 SELECT "id",
    "name",
    "emoji"
   FROM "public"."joiners";


ALTER VIEW "public"."public_joiners" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."shipments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "number" integer NOT NULL,
    "kaddy" "text",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "box_dims" "text",
    "weight_kg" numeric(8,2),
    "cost_krw" numeric(12,0),
    "cost_usd" numeric(10,2),
    "declared_value_usd" numeric(10,2),
    "customs_usd" numeric(10,2),
    "paid_on" "date",
    "shipped_on" "date",
    "delivered_on" "date",
    "tracking" "text",
    "notes" "text",
    CONSTRAINT "shipments_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'packed'::"text", 'shipping_paid'::"text", 'shipped'::"text", 'delivered'::"text"])))
);


ALTER TABLE "public"."shipments" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."public_shipments" AS
 SELECT "id",
    "number",
    "kaddy",
    "status",
    "paid_on",
    "shipped_on",
    "delivered_on"
   FROM "public"."shipments";


ALTER VIEW "public"."public_shipments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."raffles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "group_order_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "winner" "text",
    "position" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."raffles" OWNER TO "postgres";


ALTER TABLE ONLY "public"."admins"
    ADD CONSTRAINT "admins_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."bonus_claims"
    ADD CONSTRAINT "bonus_claims_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bonus_items"
    ADD CONSTRAINT "bonus_items_group_order_id_item_name_key" UNIQUE ("group_order_id", "item_name");



ALTER TABLE ONLY "public"."bonus_items"
    ADD CONSTRAINT "bonus_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."charges"
    ADD CONSTRAINT "charges_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."claims"
    ADD CONSTRAINT "claims_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."comeback_emojis"
    ADD CONSTRAINT "comeback_emojis_pkey" PRIMARY KEY ("comeback_id", "joiner_id");



ALTER TABLE ONLY "public"."comeback_roster"
    ADD CONSTRAINT "comeback_roster_comeback_id_tier_member_code_position_key" UNIQUE ("comeback_id", "tier", "member_code", "position");



ALTER TABLE ONLY "public"."comeback_roster"
    ADD CONSTRAINT "comeback_roster_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."comebacks"
    ADD CONSTRAINT "comebacks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."drops"
    ADD CONSTRAINT "drops_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."go_merch_items"
    ADD CONSTRAINT "go_merch_items_group_order_id_merch_item_id_key" UNIQUE ("group_order_id", "merch_item_id");



ALTER TABLE ONLY "public"."go_merch_items"
    ADD CONSTRAINT "go_merch_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."group_orders"
    ADD CONSTRAINT "group_orders_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."joiner_accounts"
    ADD CONSTRAINT "joiner_accounts_pkey" PRIMARY KEY ("handle");



ALTER TABLE ONLY "public"."joiners"
    ADD CONSTRAINT "joiners_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."login_attempts"
    ADD CONSTRAINT "login_attempts_pkey" PRIMARY KEY ("handle");



ALTER TABLE ONLY "public"."merch_items"
    ADD CONSTRAINT "merch_items_drop_id_name_key" UNIQUE ("drop_id", "name");



ALTER TABLE ONLY "public"."merch_items"
    ADD CONSTRAINT "merch_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."participants"
    ADD CONSTRAINT "participants_pkey" PRIMARY KEY ("group_order_id", "joiner_id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."raffles"
    ADD CONSTRAINT "raffles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."shipments"
    ADD CONSTRAINT "shipments_number_key" UNIQUE ("number");



ALTER TABLE ONLY "public"."shipments"
    ADD CONSTRAINT "shipments_pkey" PRIMARY KEY ("id");



CREATE INDEX "charges_joiner_id_idx" ON "public"."charges" USING "btree" ("joiner_id");



CREATE INDEX "claims_group_order_id_idx" ON "public"."claims" USING "btree" ("group_order_id");



CREATE INDEX "claims_joiner_id_idx" ON "public"."claims" USING "btree" ("joiner_id");



CREATE INDEX "comeback_roster_joiner_idx" ON "public"."comeback_roster" USING "btree" ("joiner_id");



CREATE INDEX "drops_comeback_id_idx" ON "public"."drops" USING "btree" ("comeback_id");



CREATE INDEX "group_orders_drop_id_idx" ON "public"."group_orders" USING "btree" ("drop_id");



CREATE INDEX "joiner_accounts_joiner_id_idx" ON "public"."joiner_accounts" USING "btree" ("joiner_id");



CREATE UNIQUE INDEX "joiners_one_host" ON "public"."joiners" USING "btree" ("is_host") WHERE "is_host";



CREATE INDEX "payments_joiner_id_idx" ON "public"."payments" USING "btree" ("joiner_id");



CREATE OR REPLACE TRIGGER "claims_add_participant" AFTER INSERT ON "public"."claims" FOR EACH ROW EXECUTE FUNCTION "public"."ensure_participant"();



ALTER TABLE ONLY "public"."admins"
    ADD CONSTRAINT "admins_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bonus_claims"
    ADD CONSTRAINT "bonus_claims_bonus_item_id_fkey" FOREIGN KEY ("bonus_item_id") REFERENCES "public"."bonus_items"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bonus_claims"
    ADD CONSTRAINT "bonus_claims_group_order_id_fkey" FOREIGN KEY ("group_order_id") REFERENCES "public"."group_orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bonus_claims"
    ADD CONSTRAINT "bonus_claims_joiner_id_fkey" FOREIGN KEY ("joiner_id") REFERENCES "public"."joiners"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bonus_items"
    ADD CONSTRAINT "bonus_items_group_order_id_fkey" FOREIGN KEY ("group_order_id") REFERENCES "public"."group_orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."charges"
    ADD CONSTRAINT "charges_group_order_id_fkey" FOREIGN KEY ("group_order_id") REFERENCES "public"."group_orders"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."charges"
    ADD CONSTRAINT "charges_joiner_id_fkey" FOREIGN KEY ("joiner_id") REFERENCES "public"."joiners"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."claims"
    ADD CONSTRAINT "claims_group_order_id_fkey" FOREIGN KEY ("group_order_id") REFERENCES "public"."group_orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."claims"
    ADD CONSTRAINT "claims_joiner_id_fkey" FOREIGN KEY ("joiner_id") REFERENCES "public"."joiners"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comeback_emojis"
    ADD CONSTRAINT "comeback_emojis_comeback_id_fkey" FOREIGN KEY ("comeback_id") REFERENCES "public"."comebacks"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comeback_emojis"
    ADD CONSTRAINT "comeback_emojis_joiner_id_fkey" FOREIGN KEY ("joiner_id") REFERENCES "public"."joiners"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comeback_roster"
    ADD CONSTRAINT "comeback_roster_comeback_id_fkey" FOREIGN KEY ("comeback_id") REFERENCES "public"."comebacks"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comeback_roster"
    ADD CONSTRAINT "comeback_roster_joiner_id_fkey" FOREIGN KEY ("joiner_id") REFERENCES "public"."joiners"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."drops"
    ADD CONSTRAINT "drops_comeback_id_fkey" FOREIGN KEY ("comeback_id") REFERENCES "public"."comebacks"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."go_merch_items"
    ADD CONSTRAINT "go_merch_items_group_order_id_fkey" FOREIGN KEY ("group_order_id") REFERENCES "public"."group_orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."go_merch_items"
    ADD CONSTRAINT "go_merch_items_merch_item_id_fkey" FOREIGN KEY ("merch_item_id") REFERENCES "public"."merch_items"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."group_orders"
    ADD CONSTRAINT "group_orders_drop_id_fkey" FOREIGN KEY ("drop_id") REFERENCES "public"."drops"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."group_orders"
    ADD CONSTRAINT "group_orders_shipment_id_fkey" FOREIGN KEY ("shipment_id") REFERENCES "public"."shipments"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."joiner_accounts"
    ADD CONSTRAINT "joiner_accounts_joiner_id_fkey" FOREIGN KEY ("joiner_id") REFERENCES "public"."joiners"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."merch_items"
    ADD CONSTRAINT "merch_items_drop_id_fkey" FOREIGN KEY ("drop_id") REFERENCES "public"."drops"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."participants"
    ADD CONSTRAINT "participants_group_order_id_fkey" FOREIGN KEY ("group_order_id") REFERENCES "public"."group_orders"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."participants"
    ADD CONSTRAINT "participants_joiner_id_fkey" FOREIGN KEY ("joiner_id") REFERENCES "public"."joiners"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_group_order_id_fkey" FOREIGN KEY ("group_order_id") REFERENCES "public"."group_orders"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_joiner_id_fkey" FOREIGN KEY ("joiner_id") REFERENCES "public"."joiners"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."raffles"
    ADD CONSTRAINT "raffles_group_order_id_fkey" FOREIGN KEY ("group_order_id") REFERENCES "public"."group_orders"("id") ON DELETE CASCADE;



CREATE POLICY "admin full access" ON "public"."bonus_claims" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin full access" ON "public"."bonus_items" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin full access" ON "public"."charges" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin full access" ON "public"."claims" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin full access" ON "public"."comeback_emojis" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin full access" ON "public"."comeback_roster" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin full access" ON "public"."comebacks" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin full access" ON "public"."drops" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin full access" ON "public"."go_merch_items" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin full access" ON "public"."group_orders" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin full access" ON "public"."joiner_accounts" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin full access" ON "public"."joiners" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin full access" ON "public"."merch_items" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin full access" ON "public"."participants" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin full access" ON "public"."payments" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin full access" ON "public"."raffles" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "admin full access" ON "public"."shipments" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



ALTER TABLE "public"."admins" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."bonus_claims" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."bonus_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."charges" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."claims" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."comeback_emojis" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."comeback_roster" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."comebacks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."drops" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."go_merch_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."group_orders" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."joiner_accounts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."joiners" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."login_attempts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."merch_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."participants" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."payments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "public can read bonus items" ON "public"."bonus_items" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "public can read comeback emojis" ON "public"."comeback_emojis" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "public can read comebacks" ON "public"."comebacks" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "public can read drops" ON "public"."drops" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "public can read go merch items" ON "public"."go_merch_items" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "public can read group orders" ON "public"."group_orders" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "public can read merch items" ON "public"."merch_items" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "public can read raffles" ON "public"."raffles" FOR SELECT TO "authenticated", "anon" USING (true);



ALTER TABLE "public"."raffles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."shipments" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";






















































































































































REVOKE ALL ON FUNCTION "public"."_auto_assign_bonus"("p_order" "uuid", "p_joiner" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."_joiner_auth"("p_handle" "text", "p_pin" "text", OUT "j_id" "uuid", OUT "err" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."admin_recompute_bonus"("p_order" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_recompute_bonus"("p_order" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_set_pin"("p_joiner_id" "uuid", "p_pin" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_set_pin"("p_joiner_id" "uuid", "p_pin" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."joiner_claim"("p_handle" "text", "p_pin" "text", "p_order" "uuid", "p_members" "text"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."joiner_claim"("p_handle" "text", "p_pin" "text", "p_order" "uuid", "p_members" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."joiner_claim"("p_handle" "text", "p_pin" "text", "p_order" "uuid", "p_members" "text"[]) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."joiner_dashboard"("p_handle" "text", "p_pin" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."joiner_dashboard"("p_handle" "text", "p_pin" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."joiner_dashboard"("p_handle" "text", "p_pin" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."joiner_pick_bonus_type"("p_handle" "text", "p_pin" "text", "p_bonus_claim_id" "uuid", "p_type" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."joiner_pick_bonus_type"("p_handle" "text", "p_pin" "text", "p_bonus_claim_id" "uuid", "p_type" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."joiner_pick_bonus_type"("p_handle" "text", "p_pin" "text", "p_bonus_claim_id" "uuid", "p_type" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."joiner_submit_payment"("p_handle" "text", "p_pin" "text", "p_amount" numeric, "p_method" "text", "p_note" "text", "p_screenshot_path" "text", "p_order_ids" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."joiner_submit_payment"("p_handle" "text", "p_pin" "text", "p_amount" numeric, "p_method" "text", "p_note" "text", "p_screenshot_path" "text", "p_order_ids" "uuid"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."joiner_submit_payment"("p_handle" "text", "p_pin" "text", "p_amount" numeric, "p_method" "text", "p_note" "text", "p_screenshot_path" "text", "p_order_ids" "uuid"[]) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."joiner_unclaim"("p_handle" "text", "p_pin" "text", "p_claim" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."joiner_unclaim"("p_handle" "text", "p_pin" "text", "p_claim" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."joiner_unclaim"("p_handle" "text", "p_pin" "text", "p_claim" "uuid") TO "authenticated";


















GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."admins" TO "anon";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."admins" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."admins" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."bonus_claims" TO "anon";
GRANT ALL ON TABLE "public"."bonus_claims" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."bonus_claims" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."bonus_items" TO "anon";
GRANT ALL ON TABLE "public"."bonus_items" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."bonus_items" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."charges" TO "anon";
GRANT ALL ON TABLE "public"."charges" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."charges" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."claims" TO "anon";
GRANT ALL ON TABLE "public"."claims" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."claims" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."comeback_emojis" TO "anon";
GRANT ALL ON TABLE "public"."comeback_emojis" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."comeback_emojis" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."comeback_roster" TO "anon";
GRANT ALL ON TABLE "public"."comeback_roster" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."comeback_roster" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."comebacks" TO "anon";
GRANT ALL ON TABLE "public"."comebacks" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."comebacks" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."drops" TO "anon";
GRANT ALL ON TABLE "public"."drops" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."drops" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."go_merch_items" TO "anon";
GRANT ALL ON TABLE "public"."go_merch_items" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."go_merch_items" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."go_stats" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."go_stats" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."go_stats" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."group_orders" TO "anon";
GRANT ALL ON TABLE "public"."group_orders" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."group_orders" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."joiner_accounts" TO "anon";
GRANT ALL ON TABLE "public"."joiner_accounts" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."joiner_accounts" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."joiners" TO "anon";
GRANT ALL ON TABLE "public"."joiners" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."joiners" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."login_attempts" TO "anon";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."login_attempts" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."login_attempts" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."merch_items" TO "anon";
GRANT ALL ON TABLE "public"."merch_items" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."merch_items" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."order_seats" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."order_seats" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."order_seats" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."participants" TO "anon";
GRANT ALL ON TABLE "public"."participants" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."participants" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."payments" TO "anon";
GRANT ALL ON TABLE "public"."payments" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."payments" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."public_joiners" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."public_joiners" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."public_joiners" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."shipments" TO "anon";
GRANT ALL ON TABLE "public"."shipments" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."shipments" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."public_shipments" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."public_shipments" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."public_shipments" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."raffles" TO "anon";
GRANT ALL ON TABLE "public"."raffles" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."raffles" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLES TO "service_role";



































drop extension if exists "pg_net";

drop policy "public can read bonus items" on "public"."bonus_items";

drop policy "public can read comeback emojis" on "public"."comeback_emojis";

drop policy "public can read comebacks" on "public"."comebacks";

drop policy "public can read drops" on "public"."drops";

drop policy "public can read go merch items" on "public"."go_merch_items";

drop policy "public can read group orders" on "public"."group_orders";

drop policy "public can read merch items" on "public"."merch_items";

drop policy "public can read raffles" on "public"."raffles";

revoke delete on table "public"."admins" from "anon";

revoke insert on table "public"."admins" from "anon";

revoke select on table "public"."admins" from "anon";

revoke update on table "public"."admins" from "anon";

revoke delete on table "public"."admins" from "authenticated";

revoke insert on table "public"."admins" from "authenticated";

revoke select on table "public"."admins" from "authenticated";

revoke update on table "public"."admins" from "authenticated";

revoke delete on table "public"."admins" from "service_role";

revoke insert on table "public"."admins" from "service_role";

revoke select on table "public"."admins" from "service_role";

revoke update on table "public"."admins" from "service_role";

revoke delete on table "public"."bonus_claims" from "anon";

revoke insert on table "public"."bonus_claims" from "anon";

revoke select on table "public"."bonus_claims" from "anon";

revoke update on table "public"."bonus_claims" from "anon";

revoke delete on table "public"."bonus_claims" from "service_role";

revoke insert on table "public"."bonus_claims" from "service_role";

revoke select on table "public"."bonus_claims" from "service_role";

revoke update on table "public"."bonus_claims" from "service_role";

revoke delete on table "public"."bonus_items" from "anon";

revoke insert on table "public"."bonus_items" from "anon";

revoke update on table "public"."bonus_items" from "anon";

revoke delete on table "public"."bonus_items" from "service_role";

revoke insert on table "public"."bonus_items" from "service_role";

revoke select on table "public"."bonus_items" from "service_role";

revoke update on table "public"."bonus_items" from "service_role";

revoke delete on table "public"."charges" from "anon";

revoke insert on table "public"."charges" from "anon";

revoke select on table "public"."charges" from "anon";

revoke update on table "public"."charges" from "anon";

revoke delete on table "public"."charges" from "service_role";

revoke insert on table "public"."charges" from "service_role";

revoke select on table "public"."charges" from "service_role";

revoke update on table "public"."charges" from "service_role";

revoke delete on table "public"."claims" from "anon";

revoke insert on table "public"."claims" from "anon";

revoke select on table "public"."claims" from "anon";

revoke update on table "public"."claims" from "anon";

revoke delete on table "public"."claims" from "service_role";

revoke insert on table "public"."claims" from "service_role";

revoke select on table "public"."claims" from "service_role";

revoke update on table "public"."claims" from "service_role";

revoke delete on table "public"."comeback_emojis" from "anon";

revoke insert on table "public"."comeback_emojis" from "anon";

revoke update on table "public"."comeback_emojis" from "anon";

revoke delete on table "public"."comeback_emojis" from "service_role";

revoke insert on table "public"."comeback_emojis" from "service_role";

revoke select on table "public"."comeback_emojis" from "service_role";

revoke update on table "public"."comeback_emojis" from "service_role";

revoke delete on table "public"."comeback_roster" from "anon";

revoke insert on table "public"."comeback_roster" from "anon";

revoke select on table "public"."comeback_roster" from "anon";

revoke update on table "public"."comeback_roster" from "anon";

revoke delete on table "public"."comeback_roster" from "service_role";

revoke insert on table "public"."comeback_roster" from "service_role";

revoke select on table "public"."comeback_roster" from "service_role";

revoke update on table "public"."comeback_roster" from "service_role";

revoke delete on table "public"."comebacks" from "anon";

revoke insert on table "public"."comebacks" from "anon";

revoke update on table "public"."comebacks" from "anon";

revoke delete on table "public"."comebacks" from "service_role";

revoke insert on table "public"."comebacks" from "service_role";

revoke select on table "public"."comebacks" from "service_role";

revoke update on table "public"."comebacks" from "service_role";

revoke delete on table "public"."drops" from "anon";

revoke insert on table "public"."drops" from "anon";

revoke update on table "public"."drops" from "anon";

revoke delete on table "public"."drops" from "service_role";

revoke insert on table "public"."drops" from "service_role";

revoke select on table "public"."drops" from "service_role";

revoke update on table "public"."drops" from "service_role";

revoke delete on table "public"."go_merch_items" from "anon";

revoke insert on table "public"."go_merch_items" from "anon";

revoke update on table "public"."go_merch_items" from "anon";

revoke delete on table "public"."go_merch_items" from "service_role";

revoke insert on table "public"."go_merch_items" from "service_role";

revoke select on table "public"."go_merch_items" from "service_role";

revoke update on table "public"."go_merch_items" from "service_role";

revoke delete on table "public"."group_orders" from "anon";

revoke insert on table "public"."group_orders" from "anon";

revoke update on table "public"."group_orders" from "anon";

revoke delete on table "public"."group_orders" from "service_role";

revoke insert on table "public"."group_orders" from "service_role";

revoke select on table "public"."group_orders" from "service_role";

revoke update on table "public"."group_orders" from "service_role";

revoke delete on table "public"."joiner_accounts" from "anon";

revoke insert on table "public"."joiner_accounts" from "anon";

revoke select on table "public"."joiner_accounts" from "anon";

revoke update on table "public"."joiner_accounts" from "anon";

revoke delete on table "public"."joiner_accounts" from "service_role";

revoke insert on table "public"."joiner_accounts" from "service_role";

revoke select on table "public"."joiner_accounts" from "service_role";

revoke update on table "public"."joiner_accounts" from "service_role";

revoke delete on table "public"."joiners" from "anon";

revoke insert on table "public"."joiners" from "anon";

revoke select on table "public"."joiners" from "anon";

revoke update on table "public"."joiners" from "anon";

revoke delete on table "public"."joiners" from "service_role";

revoke insert on table "public"."joiners" from "service_role";

revoke select on table "public"."joiners" from "service_role";

revoke update on table "public"."joiners" from "service_role";

revoke delete on table "public"."login_attempts" from "anon";

revoke insert on table "public"."login_attempts" from "anon";

revoke select on table "public"."login_attempts" from "anon";

revoke update on table "public"."login_attempts" from "anon";

revoke delete on table "public"."login_attempts" from "authenticated";

revoke insert on table "public"."login_attempts" from "authenticated";

revoke select on table "public"."login_attempts" from "authenticated";

revoke update on table "public"."login_attempts" from "authenticated";

revoke delete on table "public"."login_attempts" from "service_role";

revoke insert on table "public"."login_attempts" from "service_role";

revoke select on table "public"."login_attempts" from "service_role";

revoke update on table "public"."login_attempts" from "service_role";

revoke delete on table "public"."merch_items" from "anon";

revoke insert on table "public"."merch_items" from "anon";

revoke update on table "public"."merch_items" from "anon";

revoke delete on table "public"."merch_items" from "service_role";

revoke insert on table "public"."merch_items" from "service_role";

revoke select on table "public"."merch_items" from "service_role";

revoke update on table "public"."merch_items" from "service_role";

revoke delete on table "public"."participants" from "anon";

revoke insert on table "public"."participants" from "anon";

revoke select on table "public"."participants" from "anon";

revoke update on table "public"."participants" from "anon";

revoke delete on table "public"."participants" from "service_role";

revoke insert on table "public"."participants" from "service_role";

revoke select on table "public"."participants" from "service_role";

revoke update on table "public"."participants" from "service_role";

revoke delete on table "public"."payments" from "anon";

revoke insert on table "public"."payments" from "anon";

revoke select on table "public"."payments" from "anon";

revoke update on table "public"."payments" from "anon";

revoke delete on table "public"."payments" from "service_role";

revoke insert on table "public"."payments" from "service_role";

revoke select on table "public"."payments" from "service_role";

revoke update on table "public"."payments" from "service_role";

revoke delete on table "public"."raffles" from "anon";

revoke insert on table "public"."raffles" from "anon";

revoke update on table "public"."raffles" from "anon";

revoke delete on table "public"."raffles" from "service_role";

revoke insert on table "public"."raffles" from "service_role";

revoke select on table "public"."raffles" from "service_role";

revoke update on table "public"."raffles" from "service_role";

revoke delete on table "public"."shipments" from "anon";

revoke insert on table "public"."shipments" from "anon";

revoke select on table "public"."shipments" from "anon";

revoke update on table "public"."shipments" from "anon";

revoke delete on table "public"."shipments" from "service_role";

revoke insert on table "public"."shipments" from "service_role";

revoke select on table "public"."shipments" from "service_role";

revoke update on table "public"."shipments" from "service_role";


  create policy "public can read bonus items"
  on "public"."bonus_items"
  as permissive
  for select
  to anon, authenticated
using (true);



  create policy "public can read comeback emojis"
  on "public"."comeback_emojis"
  as permissive
  for select
  to anon, authenticated
using (true);



  create policy "public can read comebacks"
  on "public"."comebacks"
  as permissive
  for select
  to anon, authenticated
using (true);



  create policy "public can read drops"
  on "public"."drops"
  as permissive
  for select
  to anon, authenticated
using (true);



  create policy "public can read go merch items"
  on "public"."go_merch_items"
  as permissive
  for select
  to anon, authenticated
using (true);



  create policy "public can read group orders"
  on "public"."group_orders"
  as permissive
  for select
  to anon, authenticated
using (true);



  create policy "public can read merch items"
  on "public"."merch_items"
  as permissive
  for select
  to anon, authenticated
using (true);



  create policy "public can read raffles"
  on "public"."raffles"
  as permissive
  for select
  to anon, authenticated
using (true);



  create policy "host can delete payment proofs"
  on "storage"."objects"
  as permissive
  for delete
  to authenticated
using (((bucket_id = 'payment-proofs'::text) AND public.is_admin()));



  create policy "host can view payment proofs"
  on "storage"."objects"
  as permissive
  for select
  to authenticated
using (((bucket_id = 'payment-proofs'::text) AND public.is_admin()));



  create policy "host manages drop images"
  on "storage"."objects"
  as permissive
  for all
  to authenticated
using (((bucket_id = 'drop-images'::text) AND public.is_admin()))
with check (((bucket_id = 'drop-images'::text) AND public.is_admin()));



  create policy "joiners can upload payment proofs"
  on "storage"."objects"
  as permissive
  for insert
  to anon, authenticated
with check ((bucket_id = 'payment-proofs'::text));



