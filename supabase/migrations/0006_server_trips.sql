-- Campus Bus Tracker — server-side trip logging.
--
-- Trips were opened and closed by the phone publisher calling start_trip /
-- end_trip. The ESP32 units only post GPS, so with hardware alone the trips
-- table would stay empty and every analytic built on it would go blank.
--
-- Trip boundaries are exactly the journey transitions the server already
-- detects, so the log is now a side effect of advance_journey():
--
--   departure (parked -> outbound)  =>  open a trip
--   arrival   (outbound -> parked)  =>  close it
--
-- A trip therefore opens knowing only where it LEFT from. The destination is
-- written when the bus actually arrives somewhere, rather than being assumed
-- up front — which is both honest and what makes this work for a device that
-- has no idea where it is going.
--
-- arrived_at IS NULL keeps its meaning: the leg never completed.

create or replace function public.advance_journey(p_bus_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  cfg        public.journey_config%rowtype;
  pos        public.bus_positions%rowtype;
  nearest_id text;
  nearest_m  double precision;
  drift_m    double precision;
  prior_n    int;
  in_window  int;
  moving_n   int;
  from_park  double precision;
  new_state  text;
  new_origin text;
  new_dest   text;
  flipped    boolean := false;
  arrived    boolean := false;
  trip_id    bigint;
begin
  select * into cfg from public.journey_config where id = 1;
  select * into pos from public.bus_positions where bus_id = p_bus_id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no position');
  end if;

  new_state  := coalesce(pos.journey_state, 'outbound');
  new_origin := pos.origin_id;
  new_dest   := pos.destination_id;

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
    -- ---- departure: distance AND sustained speed must both agree ----
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
      new_origin := coalesce(pos.destination_id, nearest_id);
      new_dest   := pos.origin_id;
      new_state  := 'outbound';
      flipped    := true;
      update public.bus_positions
         set park_lat = null, park_lng = null
       where bus_id = p_bus_id;
    end if;

  else
    -- ---- arrival: near a terminal AND genuinely settled ----
    if nearest_m <= cfg.arrive_radius_m then
      select max(public.meters_between(pos.lat, pos.lng, f.lat, f.lng)),
             count(*)
        into drift_m, in_window
      from public.bus_fixes f
      where f.bus_id = p_bus_id
        and f.at >= now() - make_interval(secs => cfg.parked_window_sec);

      -- Coverage looks OUTSIDE the window on purpose: the oldest fix inside a
      -- 30 s window is by definition younger than 30 s, so a within-window
      -- span can never reach the threshold. A fix from before the window
      -- opened is what proves the bus has really been sitting here.
      select count(*) into prior_n
      from public.bus_fixes f
      where f.bus_id = p_bus_id
        and f.at < now() - make_interval(secs => cfg.parked_window_sec);

      if prior_n > 0
         and in_window >= 2
         and coalesce(drift_m, 1e9) <= cfg.parked_max_drift_m then
        new_state := 'parked';
        new_dest  := nearest_id;
        arrived   := true;
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

  -- ------------------------------------------------------------- trip log
  if flipped then
    -- Anything still open is stale (the bus reached a terminal without the
    -- arrival being recorded, e.g. it was offline). Leave arrived_at null so
    -- it reads as "never completed" rather than inventing a time.
    update public.trips
       set destination_id = coalesce(destination_id, new_origin)
     where bus_id = p_bus_id and arrived_at is null;

    insert into public.trips (bus_id, route_id, origin_id, destination_id)
    values (p_bus_id, pos.route_id, new_origin, new_dest)
    returning id into trip_id;

  elsif arrived then
    -- Close the open leg, recording where it actually ended up.
    update public.trips
       set arrived_at = now(),
           destination_id = coalesce(nearest_id, destination_id)
     where id = (
       select id from public.trips
        where bus_id = p_bus_id and arrived_at is null
        order by departed_at desc
        limit 1
     )
    returning id into trip_id;
  end if;

  return jsonb_build_object(
    'ok', true, 'state', new_state, 'origin', new_origin,
    'destination', new_dest, 'flipped', flipped, 'arrived', arrived,
    'trip_id', trip_id,
    'nearest_m', round(nearest_m::numeric, 1));
end;
$$;

-- Trips opened by the server have no device to attribute them to, so the old
-- start_trip / end_trip RPCs stay for the phone app but are no longer the only
-- way trips get written. Nothing to change there.

-- Housekeeping: a bus whose claim expired mid-leg leaves an open trip forever.
-- This closes nothing and invents nothing — it just makes them findable.
create or replace view public.stale_open_trips as
select t.id, t.bus_id, t.origin_id, t.departed_at,
       now() - t.departed_at as open_for
from public.trips t
left join public.bus_claims c on c.bus_id = t.bus_id
where t.arrived_at is null
  and (c.bus_id is null or c.last_seen < now() - interval '30 minutes')
  and t.departed_at < now() - interval '30 minutes';
