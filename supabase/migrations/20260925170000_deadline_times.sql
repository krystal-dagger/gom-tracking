-- Deadlines can now carry a time and time zone. The dashboard saves drops.deadline_time as "HH:MM Area/City"
-- (for example "23:59 Asia/Seoul"); older free-text values like "11:59 PM KST" or "9 PM" are still understood,
-- and a time with no zone is KST. With no (readable) time, the deadline is the end of that day in KST, same as before.
-- Keep this in step with parseTime() / dueMs() in index.html.
CREATE OR REPLACE FUNCTION "public"."drop_due_at"("p_date" "date", "p_time" "text") RETURNS timestamp with time zone
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO 'public'
    AS $$
declare
  m  text[];
  h  int;
  mi int;
  ap text;
  z  text;
  tz text;
begin
  if p_date is null then return null; end if;
  m := regexp_match(btrim(coalesce(p_time, '')), '^(\d{1,2})(?:[:.](\d{2}))?(?:\s*([ap])\.?m\.?(?![a-z]))?\s*(.*)$', 'i');
  if m is not null then
    h := m[1]::int; mi := coalesce(m[2], '0')::int; ap := lower(coalesce(m[3], '')); z := btrim(m[4]);
    if ap <> '' then
      if h between 1 and 12 then h := h % 12 + case when ap = 'p' then 12 else 0 end; else h := 99; end if;
    end if;
    if h <= 23 and mi <= 59 then
      tz := case when z = '' then 'Asia/Seoul' else coalesce(
        '{"KST":"Asia/Seoul","JST":"Asia/Tokyo","CST":"Asia/Shanghai","HKT":"Asia/Hong_Kong","SGT":"Asia/Singapore",
          "PHT":"Asia/Manila","WIB":"Asia/Jakarta","ICT":"Asia/Bangkok","AEST":"Australia/Sydney","AEDT":"Australia/Sydney",
          "GMT":"UTC","UTC":"UTC","BST":"Europe/London","CET":"Europe/Paris","CEST":"Europe/Paris",
          "ET":"America/New_York","EST":"America/New_York","EDT":"America/New_York",
          "PT":"America/Los_Angeles","PST":"America/Los_Angeles","PDT":"America/Los_Angeles",
          "CT":"America/Chicago","CDT":"America/Chicago","MT":"America/Denver","MST":"America/Denver","MDT":"America/Denver"}'::jsonb ->> upper(z),
        (select n.name from pg_catalog.pg_timezone_names n where n.name = z limit 1)) end;
      if tz is not null then return (p_date + make_time(h, mi, 0)) at time zone tz; end if;
    end if;
  end if;
  return (p_date + 1)::timestamp at time zone 'Asia/Seoul';
end $$;


ALTER FUNCTION "public"."drop_due_at"("p_date" "date", "p_time" "text") OWNER TO "postgres";

GRANT ALL ON FUNCTION "public"."drop_due_at"("p_date" "date", "p_time" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."drop_due_at"("p_date" "date", "p_time" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."drop_due_at"("p_date" "date", "p_time" "text") TO "service_role";


-- Claiming and dropping a claim now close at the deadline's exact time. Only the deadline check changed in each.
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

  update public.claims set status = 'dropped' where id = p_claim;
  return jsonb_build_object('ok', true);
end $$;
