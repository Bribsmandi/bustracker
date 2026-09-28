-- Campus Bus Tracker — server-side journey detection.
--
-- The phone publisher worked out parked/departed and which direction a bus was
-- going. The ESP32 units will not: they post raw GPS and nothing else. So the
-- same state machine moves here, where it runs for every bus regardless of what
-- is transmitting, and can be retuned without reflashing hardware in a bus.
--
-- The rules are the agreed ones, unchanged:
--   parked   := within 40 m of a terminal AND moved < 15 m over the last 30 s
--   departed := > 25 m from the park anchor AND speed > 2 m/s for 3 fixes
--
-- Requiring two independent signals for each transition is the point: a
-- stationary phone/GPS drifts 5-15 m, so distance alone invents departures;
-- fused speed is unreliable below walking pace, so speed alone invents parks.

-- ------------------------------------------------------------------ tunables
create table if not exists public.journey_config (
  id                      int primary key default 1,
  arrive_radius_m         double precision not null default 40,
  parked_window_sec       int              not null default 30,
  parked_max_drift_m      double precision not null default 15,
  depart_min_distance_m   double precision not null default 25,
  depart_min_speed_mps    double precision not null default 2,
  depart_min_fixes        int              not null default 3,
  constraint one_row check (id = 1)
);
insert into public.journey_config (id) values (1) on conflict (id) do nothing;

alter table public.journey_config enable row level security;
drop policy if exists "anon read journey config" on public.journey_config;
create policy "anon read journey config" on public.journey_config
  for select using (true);

-- --------------------------------------------------------------- stop coords
-- The device knows nothing about stops, so the server needs them.
create table if not exists public.stops (
  id          text primary key,
  name        text not null,
  lat         double precision not null,
  lng         double precision not null,
  is_terminal boolean not null default false
);

alter table public.stops enable row level security;
drop policy if exists "anon read stops" on public.stops;
create policy "anon read stops" on public.stops for select using (true);

-- ------------------------------------------------------------- recent fixes
-- A short trail per bus, just long enough to answer "has it settled?" and
-- "has it been moving for N fixes?". Trimmed on every insert; never grows.
create table if not exists public.bus_fixes (
  id      bigint generated always as identity primary key,
  bus_id  text not null,
  lat     double precision not null,
  lng     double precision not null,
  speed   double precision,
  at      timestamptz not null default now()
);
create index if not exists idx_bus_fixes_bus_at
  on public.bus_fixes (bus_id, at desc);

alter table public.bus_fixes enable row level security;
drop policy if exists "anon read fixes" on public.bus_fixes;
create policy "anon read fixes" on public.bus_fixes for select using (true);

-- Where each bus came to rest, so departure is measured from the actual
-- parking spot rather than the stop's nominal centre.
alter table public.bus_positions
  add column if not exists park_lat double precision,
  add column if not exists park_lng double precision;

-- ------------------------------------------------------------------ distance
create or replace function public.meters_between(
  lat1 double precision, lng1 double precision,
  lat2 double precision, lng2 double precision
) returns double precision
language sql immutable parallel safe as $$
  select 2 * 6371000 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) *
    power(sin(radians(lng2 - lng1) / 2), 2)
  ));
$$;

-- ------------------------------------------------------ advance_journey()
-- Runs after every position write. Returns the new journey state.
create or replace function public.advance_journey(p_bus_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  cfg        public.journey_config%rowtype;
  pos        public.bus_positions%rowtype;
  -- Scalars, not a %rowtype: plpgsql forbids a record variable in a
  -- multiple-item INTO list, which is what selecting the stop plus its
  -- distance in one go requires.
  nearest_id text;
  nearest_m  double precision;
  drift_m    double precision;
  span_sec   double precision;
  moving_n   int;
  from_park  double precision;
  new_state  text;
  new_origin text;
  new_dest   text;
  flipped    boolean := false;
begin
  select * into cfg from public.journey_config where id = 1;
  select * into pos from public.bus_positions where bus_id = p_bus_id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no position');
  end if;

  new_state  := coalesce(pos.journey_state, 'outbound');
  new_origin := pos.origin_id;
  new_dest   := pos.destination_id;

  -- Closest terminal, and how far away it is.
  select s.id, public.meters_between(pos.lat, pos.lng, s.lat, s.lng)
    into nearest_id, nearest_m
  from public.stops s
  where s.is_terminal
  order by public.meters_between(pos.lat, pos.lng, s.lat, s.lng)
  limit 1;

  if nearest_id is null then
    return jsonb_build_object('ok', false, 'reason', 'no terminals configured');
  end if;

  if new_state = 'parked' then
    -- ---- departure test: distance AND sustained speed must both agree ----
    from_park := case
      when pos.park_lat is null then 0
      else public.meters_between(pos.lat, pos.lng, pos.park_lat, pos.park_lng)
    end;

    select count(*) into moving_n from (
      select f.speed from public.bus_fixes f
       where f.bus_id = p_bus_id
       order by f.at desc
       limit cfg.depart_min_fixes
    ) recent
    where recent.speed >= cfg.depart_min_speed_mps;

    if from_park > cfg.depart_min_distance_m
       and moving_n >= cfg.depart_min_fixes then
      -- Pulling away: the terminal just left becomes the new origin.
      new_origin := coalesce(pos.destination_id, nearest_id);
      new_dest   := pos.origin_id;
      new_state  := 'outbound';
      flipped    := true;
      update public.bus_positions
         set park_lat = null, park_lng = null
       where bus_id = p_bus_id;
    end if;

  else
    -- ---- arrival test: near a terminal AND genuinely settled ----
    if nearest_m <= cfg.arrive_radius_m then
      -- How far the bus has wandered over the settle window.
      select max(public.meters_between(pos.lat, pos.lng, f.lat, f.lng)),
             count(*)
        into drift_m, moving_n
      from public.bus_fixes f
      where f.bus_id = p_bus_id
        and f.at >= now() - make_interval(secs => cfg.parked_window_sec);

      -- Coverage check. Note this deliberately looks OUTSIDE the window: the
      -- oldest fix *inside* a 30 s window is by definition younger than 30 s,
      -- so measuring the span within the window can never reach it. What
      -- actually proves the bus has been here a full window is the existence
      -- of a fix from before the window opened.
      select count(*) into span_sec
      from public.bus_fixes f
      where f.bus_id = p_bus_id
        and f.at < now() - make_interval(secs => cfg.parked_window_sec);

      if span_sec > 0
         and moving_n >= 2
         and coalesce(drift_m, 1e9) <= cfg.parked_max_drift_m then
        new_state := 'parked';
        new_dest  := nearest_id;
        update public.bus_positions
           set park_lat = pos.lat, park_lng = pos.lng
         where bus_id = p_bus_id;
      end if;
    end if;
  end if;

  update public.bus_positions
     set journey_state  = new_state,
         origin_id      = new_origin,
         destination_id = new_dest
   where bus_id = p_bus_id;

  return jsonb_build_object(
    'ok', true, 'state', new_state, 'origin', new_origin,
    'destination', new_dest, 'flipped', flipped, 'nearest_m', round(nearest_m::numeric, 1));
end;
$$;

-- ------------------------------------------------- publish_position v2
-- Same signature the hardware spec documents. Journey fields are now ignored
-- if supplied: the server decides, so a phone and an ESP32 behave identically.
create or replace function public.publish_position(
  p_bus_id        text,
  p_device_id     text,
  p_lat           double precision,
  p_lng           double precision,
  p_speed         double precision default null,
  p_heading       double precision default null,
  p_route_id      text default null,
  p_origin_id     text default null,
  p_destination_id text default null,
  p_journey_state text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  holder  text;
  journey jsonb;
begin
  select device_id into holder from public.bus_claims where bus_id = p_bus_id;
  if holder is null then
    return jsonb_build_object('ok', false, 'reason', 'no active claim — call claim_bus first');
  end if;
  if holder <> p_device_id then
    return jsonb_build_object('ok', false, 'holder', holder,
      'reason', 'another device holds this bus');
  end if;

  update public.bus_claims set last_seen = now() where bus_id = p_bus_id;

  insert into public.bus_positions as bp
    (bus_id, lat, lng, speed, heading, route_id, device_id,
     origin_id, destination_id, journey_state)
  values
    (p_bus_id, p_lat, p_lng, p_speed, p_heading, p_route_id, p_device_id,
     p_origin_id, p_destination_id, coalesce(p_journey_state, 'outbound'))
  on conflict (bus_id) do update set
    lat = excluded.lat,
    lng = excluded.lng,
    speed = excluded.speed,
    heading = excluded.heading,
    route_id = coalesce(excluded.route_id, bp.route_id),
    device_id = excluded.device_id;

  insert into public.bus_fixes (bus_id, lat, lng, speed)
  values (p_bus_id, p_lat, p_lng, p_speed);

  -- Keep only what the window needs; this table must never grow unbounded.
  delete from public.bus_fixes
   where bus_id = p_bus_id
     and at < now() - interval '5 minutes';

  journey := public.advance_journey(p_bus_id);

  return jsonb_build_object('ok', true, 'journey', journey);
end;
$$;

grant execute on function public.advance_journey(text) to anon, authenticated;
grant execute on function public.meters_between(
  double precision, double precision, double precision, double precision)
  to anon, authenticated;
