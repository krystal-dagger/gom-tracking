-- Joiners can have a different emoji on every group order.
--   * Each joiner's emoji for an order lives on their participants row (one per joiner per order, created with
--     their first claim there) and stays put after that, even if their default emoji changes later.
--   * A new participant starts from their comeback emoji (if the order's drop is in a comeback and they're on its
--     list) or else their default emoji, but only if nobody else on the order already has it and it isn't the
--     order's own emoji. Otherwise a joiner claiming on the site is asked to pick another one. When the host adds
--     the claim instead, the emoji is left empty for the host to fill in on the Claims and shipping tab.
--   * No two joiners on one order can share an emoji (enforced by a unique index; the variation selector U+FE0F
--     is ignored when comparing, so "❤️" and "❤" count as the same).

CREATE OR REPLACE FUNCTION "public"."emoji_key"("p_emoji" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$ select nullif(replace(btrim(coalesce(p_emoji, '')), U&'\FE0F', ''), '') $$;

ALTER FUNCTION "public"."emoji_key"("p_emoji" "text") OWNER TO "postgres";

ALTER TABLE "public"."participants"
    ADD COLUMN IF NOT EXISTS "emoji" "text",
    ADD COLUMN IF NOT EXISTS "emoji_key" "text" GENERATED ALWAYS AS ("public"."emoji_key"("emoji")) STORED;

CREATE UNIQUE INDEX IF NOT EXISTS "participants_order_emoji_key"
    ON "public"."participants" ("group_order_id", "emoji_key") WHERE "emoji_key" IS NOT NULL;


-- The emoji a joiner would start with on an order: their comeback emoji for the order's comeback, else their default.
CREATE OR REPLACE FUNCTION "public"."_order_emoji_default"("p_order" "uuid", "p_joiner" "uuid") RETURNS "text"
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$
  select coalesce(
    (select ce.emoji from public.group_orders g join public.drops d on d.id = g.drop_id
       join public.comeback_emojis ce on ce.comeback_id = d.comeback_id and ce.joiner_id = p_joiner
      where g.id = p_order),
    (select j.emoji from public.joiners j where j.id = p_joiner))
$$;

ALTER FUNCTION "public"."_order_emoji_default"("p_order" "uuid", "p_joiner" "uuid") OWNER TO "postgres";

-- Can this joiner use this emoji on this order? Not if it's the order's own emoji or another joiner there has it.
CREATE OR REPLACE FUNCTION "public"."_order_emoji_free"("p_order" "uuid", "p_joiner" "uuid", "p_emoji" "text") RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$
  select public.emoji_key(p_emoji) is not null
     and not exists (select 1 from public.group_orders g where g.id = p_order and public.emoji_key(g.emoji) = public.emoji_key(p_emoji))
     and not exists (select 1 from public.participants p
                      where p.group_order_id = p_order and p.joiner_id <> p_joiner and p.emoji_key = public.emoji_key(p_emoji))
$$;

ALTER FUNCTION "public"."_order_emoji_free"("p_order" "uuid", "p_joiner" "uuid", "p_emoji" "text") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "public"."_order_emoji_default"("p_order" "uuid", "p_joiner" "uuid") FROM PUBLIC;
REVOKE ALL ON FUNCTION "public"."_order_emoji_free"("p_order" "uuid", "p_joiner" "uuid", "p_emoji" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_order_emoji_default"("p_order" "uuid", "p_joiner" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."_order_emoji_free"("p_order" "uuid", "p_joiner" "uuid", "p_emoji" "text") TO "authenticated";


-- A claim's first row for a joiner on an order also gives them their emoji there, when it's free.
CREATE OR REPLACE FUNCTION "public"."ensure_participant"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare
  e text;
begin
  if exists (select 1 from public.participants p where p.group_order_id = new.group_order_id and p.joiner_id = new.joiner_id) then
    return new;
  end if;
  e := public._order_emoji_default(new.group_order_id, new.joiner_id);
  if e is not null and not public._order_emoji_free(new.group_order_id, new.joiner_id, e) then e := null; end if;
  begin
    insert into public.participants (group_order_id, joiner_id, emoji)
    values (new.group_order_id, new.joiner_id, e)
    on conflict do nothing;
  exception when unique_violation then
    insert into public.participants (group_order_id, joiner_id) values (new.group_order_id, new.joiner_id)
    on conflict do nothing;
  end;
  return new;
end $$;


-- Give everyone already on an order the emoji they've been showing with, first claimer first. A joiner whose emoji
-- is already taken on that order (or is the order's own emoji) is left empty for the host to fix.
DO $$
declare
  r record;
  e text;
begin
  for r in
    select p.group_order_id, p.joiner_id
      from public.participants p
      left join lateral (select min(c.created_at) as first_at from public.claims c
                          where c.group_order_id = p.group_order_id and c.joiner_id = p.joiner_id) f on true
     where p.emoji is null
     order by p.group_order_id, f.first_at nulls last, p.joiner_id
  loop
    e := public._order_emoji_default(r.group_order_id, r.joiner_id);
    if e is not null and public._order_emoji_free(r.group_order_id, r.joiner_id, e) then
      update public.participants set emoji = e where group_order_id = r.group_order_id and joiner_id = r.joiner_id;
    end if;
  end loop;
end $$;


-- Claims on the public grid show the emoji the joiner has on that order (empty, shown as ❔, until they have one).
CREATE OR REPLACE VIEW "public"."order_seats" AS
 SELECT "c"."id" AS "claim_id",
    "c"."group_order_id",
    "c"."member_code",
    "c"."items",
    "c"."source",
    "c"."roster_pos",
    "c"."created_at",
    CASE WHEN ("p"."joiner_id" IS NOT NULL) THEN "p"."emoji" ELSE COALESCE("ce"."emoji", "j"."emoji") END AS "emoji"
   FROM ((((("public"."claims" "c"
     JOIN "public"."joiners" "j" ON (("j"."id" = "c"."joiner_id")))
     JOIN "public"."group_orders" "g" ON (("g"."id" = "c"."group_order_id")))
     JOIN "public"."drops" "d" ON (("d"."id" = "g"."drop_id")))
     LEFT JOIN "public"."participants" "p" ON ((("p"."group_order_id" = "c"."group_order_id") AND ("p"."joiner_id" = "c"."joiner_id"))))
     LEFT JOIN "public"."comeback_emojis" "ce" ON ((("ce"."joiner_id" = "c"."joiner_id") AND ("ce"."comeback_id" = "d"."comeback_id"))))
  WHERE ("c"."status" = 'filled'::"text");

-- Who has which emoji on each order, for the joiner key on the site (nothing else from participants is exposed).
CREATE OR REPLACE VIEW "public"."public_order_emojis" AS
 SELECT "group_order_id",
    "joiner_id",
    "emoji"
   FROM "public"."participants"
  WHERE ("emoji" IS NOT NULL);

ALTER VIEW "public"."public_order_emojis" OWNER TO "postgres";
GRANT SELECT ON TABLE "public"."public_order_emojis" TO "anon";
GRANT SELECT ON TABLE "public"."public_order_emojis" TO "authenticated";
GRANT SELECT ON TABLE "public"."public_order_emojis" TO "service_role";


-- joiner_claim takes an optional p_emoji: the emoji a joiner picked when their usual one is taken on the order.
-- Callers that leave it out keep working.
DROP FUNCTION IF EXISTS "public"."joiner_claim"("p_handle" "text", "p_pin" "text", "p_order" "uuid", "p_members" "text"[]);

CREATE OR REPLACE FUNCTION "public"."joiner_claim"("p_handle" "text", "p_pin" "text", "p_order" "uuid", "p_members" "text"[], "p_emoji" "text" DEFAULT NULL) RETURNS "jsonb"
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

  if not merch and n > 0 then
    perform public._auto_assign_bonus(p_order, a.j_id);
  end if;

  return jsonb_build_object('ok', true, 'added', n);
end $$;


ALTER FUNCTION "public"."joiner_claim"("p_handle" "text", "p_pin" "text", "p_order" "uuid", "p_members" "text"[], "p_emoji" "text") OWNER TO "postgres";

REVOKE ALL ON FUNCTION "public"."joiner_claim"("p_handle" "text", "p_pin" "text", "p_order" "uuid", "p_members" "text"[], "p_emoji" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."joiner_claim"("p_handle" "text", "p_pin" "text", "p_order" "uuid", "p_members" "text"[], "p_emoji" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."joiner_claim"("p_handle" "text", "p_pin" "text", "p_order" "uuid", "p_members" "text"[], "p_emoji" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."joiner_claim"("p_handle" "text", "p_pin" "text", "p_order" "uuid", "p_members" "text"[], "p_emoji" "text") TO "service_role";
