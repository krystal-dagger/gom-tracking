-- Raffles, part 2.
--   * A raffle is either the order's fancall/fansign raffle (kind 'event') or an extra raffle incentive ('extra').
--   * Joiners say whether they want to be entered in each raffle on an order: required before their first claim
--     there, kept for later claims, and changeable until the raffle is drawn or the order's initials payment is due.

ALTER TABLE "public"."raffles" ADD COLUMN IF NOT EXISTS "kind" "text" DEFAULT 'extra'::"text" NOT NULL;
ALTER TABLE "public"."raffles" DROP CONSTRAINT IF EXISTS "raffles_kind_check";
ALTER TABLE "public"."raffles" ADD CONSTRAINT "raffles_kind_check" CHECK ("kind" = ANY (ARRAY['event'::"text", 'extra'::"text"]));

CREATE TABLE IF NOT EXISTS "public"."raffle_entries" (
    "raffle_id" "uuid" NOT NULL REFERENCES "public"."raffles"("id") ON DELETE CASCADE,
    "joiner_id" "uuid" NOT NULL REFERENCES "public"."joiners"("id") ON DELETE CASCADE,
    "entered" boolean NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    PRIMARY KEY ("raffle_id", "joiner_id")
);
ALTER TABLE "public"."raffle_entries" OWNER TO "postgres";
ALTER TABLE "public"."raffle_entries" ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "admin full access" ON "public"."raffle_entries";
CREATE POLICY "admin full access" ON "public"."raffle_entries" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());
GRANT ALL ON TABLE "public"."raffle_entries" TO "authenticated";
GRANT ALL ON TABLE "public"."raffle_entries" TO "service_role";

-- Orders already marked as a fancall/fansign raffle get their event raffle, and orders with a planned number of
-- raffles get a row for each one not added yet, so joiners have something to answer.
INSERT INTO "public"."raffles" ("group_order_id", "name", "kind", "position")
SELECT g.id, initcap(split_part(d.event_type, ' ', 1)) || case when d.event_type like '% & %' then ' & fansign' else '' end || ' raffle', 'event', -1
  FROM "public"."group_orders" g JOIN "public"."drops" d ON d.id = g.drop_id
 WHERE g.event_mode = 'raffle' AND d.event_type <> 'none'
   AND NOT EXISTS (SELECT 1 FROM "public"."raffles" r WHERE r.group_order_id = g.id AND r.kind = 'event');
INSERT INTO "public"."raffles" ("group_order_id", "name", "kind", "position")
SELECT g.id, 'Raffle ' || n, 'extra', n - 1
  FROM "public"."group_orders" g
  CROSS JOIN LATERAL generate_series((SELECT count(*) FROM "public"."raffles" r WHERE r.group_order_id = g.id AND r.kind = 'extra') + 1, g.number_of_raffles) n;


-- Checks (p_write = false) or saves (p_write = true) a joiner's raffle answers for an order. When checking, returns
-- the first raffle they still owe an answer for, or null. When saving, answers to raffles already drawn, and changes
-- after the initials payment deadline, are ignored.
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
  select g.payment_deadline is not null and now() > public.drop_due_at(g.payment_deadline, g.payment_deadline_time)
    into late from public.group_orders g where g.id = p_order;
  for r in select x.id, x.name, x.winner_joiner_id, x.winner from public.raffles x where x.group_order_id = p_order order by x.position, x.name loop
    v := case when jsonb_typeof(p_raffles) = 'object' then p_raffles -> (r.id::text) else null end;
    had := exists (select 1 from public.raffle_entries e where e.raffle_id = r.id and e.joiner_id = p_joiner);
    if not p_write then
      if not had and (v is null or jsonb_typeof(v) <> 'boolean') and r.winner_joiner_id is null and r.winner is null then return r.name; end if;
    elsif v is not null and jsonb_typeof(v) = 'boolean' and r.winner_joiner_id is null and r.winner is null and not (had and coalesce(late, false)) then
      insert into public.raffle_entries (raffle_id, joiner_id, entered, updated_at) values (r.id, p_joiner, v::text::boolean, now())
      on conflict (raffle_id, joiner_id) do update set entered = excluded.entered, updated_at = now();
    end if;
  end loop;
  return null;
end $$;

ALTER FUNCTION "public"."_raffle_answers"("p_order" "uuid", "p_joiner" "uuid", "p_raffles" "jsonb", "p_write" boolean) OWNER TO "postgres";
REVOKE ALL ON FUNCTION "public"."_raffle_answers"("p_order" "uuid", "p_joiner" "uuid", "p_raffles" "jsonb", "p_write" boolean) FROM PUBLIC;


-- A joiner changing their answer for one raffle on an order they're in.
CREATE OR REPLACE FUNCTION "public"."joiner_set_raffle_entry"("p_handle" "text", "p_pin" "text", "p_raffle" "uuid", "p_entered" boolean) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  a record;
  r public.raffles%rowtype;
  g public.group_orders%rowtype;
begin
  select * into a from public._joiner_auth(p_handle, p_pin);
  if a.err is not null then return jsonb_build_object('error', a.err); end if;
  if p_entered is null then return jsonb_build_object('error', 'nothing'); end if;
  select * into r from public.raffles where id = p_raffle;
  if not found then return jsonb_build_object('error', 'not_found'); end if;
  if not exists (select 1 from public.claims c where c.group_order_id = r.group_order_id and c.joiner_id = a.j_id) then
    return jsonb_build_object('error', 'not_found');
  end if;
  if r.winner_joiner_id is not null or r.winner is not null then return jsonb_build_object('error', 'drawn'); end if;
  select * into g from public.group_orders where id = r.group_order_id;
  if g.payment_deadline is not null and now() > public.drop_due_at(g.payment_deadline, g.payment_deadline_time) then
    return jsonb_build_object('error', 'closed');
  end if;
  insert into public.raffle_entries (raffle_id, joiner_id, entered, updated_at) values (r.id, a.j_id, p_entered, now())
  on conflict (raffle_id, joiner_id) do update set entered = excluded.entered, updated_at = now();
  return jsonb_build_object('ok', true);
end $$;

ALTER FUNCTION "public"."joiner_set_raffle_entry"("p_handle" "text", "p_pin" "text", "p_raffle" "uuid", "p_entered" boolean) OWNER TO "postgres";
REVOKE ALL ON FUNCTION "public"."joiner_set_raffle_entry"("p_handle" "text", "p_pin" "text", "p_raffle" "uuid", "p_entered" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."joiner_set_raffle_entry"("p_handle" "text", "p_pin" "text", "p_raffle" "uuid", "p_entered" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."joiner_set_raffle_entry"("p_handle" "text", "p_pin" "text", "p_raffle" "uuid", "p_entered" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."joiner_set_raffle_entry"("p_handle" "text", "p_pin" "text", "p_raffle" "uuid", "p_entered" boolean) TO "service_role";


-- The joiner's dashboard includes their raffle answers.
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
                from public.bonus_claims b where b.joiner_id = a.id and b.status = 'filled'),
    'raffle_entries', (select coalesce(jsonb_agg(jsonb_build_object('raffle_id', e.raffle_id, 'entered', e.entered)), '[]'::jsonb)
                from public.raffle_entries e where e.joiner_id = a.id)
  );
end $$;


-- joiner_claim takes the joiner's raffle answers (p_raffles) and won't add a first claim without them.
DROP FUNCTION IF EXISTS "public"."joiner_claim"("p_handle" "text", "p_pin" "text", "p_order" "uuid", "p_members" "text"[], "p_emoji" "text");

CREATE OR REPLACE FUNCTION "public"."joiner_claim"("p_handle" "text", "p_pin" "text", "p_order" "uuid", "p_members" "text"[], "p_emoji" "text" DEFAULT NULL, "p_raffles" "jsonb" DEFAULT NULL) RETURNS "jsonb"
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
  miss    text;
  onlist  boolean;
  stand   text;
  src     text;
  full_code text;
  cnt     int;
  mine    text;
  want    text;
begin
  select * into a from public._joiner_auth(p_handle, p_pin);
  if a.err is not null then return jsonb_build_object('error', a.err); end if;

  select * into g from public.group_orders where id = p_order;
  if not found or g.status <> 'Claims Open' then return jsonb_build_object('error', 'closed'); end if;
  select * into d from public.drops where id = g.drop_id;
  -- the deadline lives on the drop: its date plus optional time and zone (end of that day in KST when there's no time)
  if d.deadline is not null and now() > public.drop_due_at(d.deadline, d.deadline_time) then
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

  -- Raffles on the order: every one this joiner hasn't answered yet needs a yes/no in p_raffles ({"<raffle id>": true}).
  -- Answers they already gave are kept (and can be changed here too, until the raffle is drawn or payment is due).
  miss := public._raffle_answers(p_order, a.j_id, p_raffles, false);
  if miss is not null then return jsonb_build_object('error', 'raffle_answers', 'detail', miss); end if;

  -- This joiner's emoji on this order. It's kept from their first claim here. Otherwise it's the one they picked, or
  -- their comeback/default emoji, as long as nobody else on the order has it and it isn't the order's own emoji.
  select p.emoji into mine from public.participants p where p.group_order_id = p_order and p.joiner_id = a.j_id;
  if mine is null then
    want := coalesce(nullif(btrim(coalesce(p_emoji, '')), ''), public._order_emoji_default(p_order, a.j_id));
    if want is null then return jsonb_build_object('error', 'emoji_needed'); end if;
    if char_length(want) > 16 or want ~ '[[:alpha:][:digit:][:space:]]' then
      return jsonb_build_object('error', 'bad_emoji');
    end if;
    if not public._order_emoji_free(p_order, a.j_id, want) then
      return jsonb_build_object('error', 'emoji_taken', 'detail', want);
    end if;
    begin
      insert into public.participants (group_order_id, joiner_id, emoji) values (p_order, a.j_id, want)
      on conflict (group_order_id, joiner_id) do update set emoji = excluded.emoji;
    exception when unique_violation then
      return jsonb_build_object('error', 'emoji_taken', 'detail', want);
    end;
  end if;

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

  perform public._raffle_answers(p_order, a.j_id, p_raffles, true);

  if not merch and n > 0 then
    perform public._auto_assign_bonus(p_order, a.j_id);
  end if;

  return jsonb_build_object('ok', true, 'added', n);
end $$;


ALTER FUNCTION "public"."joiner_claim"("p_handle" "text", "p_pin" "text", "p_order" "uuid", "p_members" "text"[], "p_emoji" "text", "p_raffles" "jsonb") OWNER TO "postgres";
REVOKE ALL ON FUNCTION "public"."joiner_claim"("p_handle" "text", "p_pin" "text", "p_order" "uuid", "p_members" "text"[], "p_emoji" "text", "p_raffles" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."joiner_claim"("p_handle" "text", "p_pin" "text", "p_order" "uuid", "p_members" "text"[], "p_emoji" "text", "p_raffles" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."joiner_claim"("p_handle" "text", "p_pin" "text", "p_order" "uuid", "p_members" "text"[], "p_emoji" "text", "p_raffles" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."joiner_claim"("p_handle" "text", "p_pin" "text", "p_order" "uuid", "p_members" "text"[], "p_emoji" "text", "p_raffles" "jsonb") TO "service_role";
