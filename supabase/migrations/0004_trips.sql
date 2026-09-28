-- Campus Bus Tracker — trip log.
--
-- One row per leg a bus actually drove: when it left a terminal and when it
-- reached the next one. Deliberately minimal — no distance, no position
-- history, no status column. Everything asked for is derivable:
--
--   trips today          count(*) where departed_at::date = today
--   departure time       departed_at
--   arrival time         arrived_at
--   how long the leg took arrived_at - departed_at
--   how long it waited   next departed_at - previous arrived_at
--
-- A NULL arrived_at means the leg never completed (app killed, phone died).
-- That is information, not an error — analytics filters those out.

create table if not exists public.trips (
  id             bigint generated always as identity primary key,
  bus_id         text        not null,
  route_id       text,
  origin_id      text        not null,
  destination_id text        not null,
  departed_at    timestamptz not null default now(),
  arrived_at     timestamptz
);

create index if not exists idx_trips_bus_departed
  on public.trips (bus_id, departed_at desc);

alter table public.trips enable row level security;

drop policy if exists "anon read trips" on public.trips;
create policy "anon read trips" on public.trips for select using (true);
-- No direct anon writes: the functions below verify the device holds the claim.

-- --------------------------------------------------------------- start_trip
-- Opens a leg. Returns the new trip id.
create or replace function public.start_trip(
  p_bus_id         text,
  p_device_id      text,
  p_route_id       text,
  p_origin_id      text,
  p_destination_id text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  holder  text;
  new_id  bigint;
begin
  select device_id into holder from public.bus_claims where bus_id = p_bus_id;
  if holder is null or holder <> p_device_id then
    return jsonb_build_object('ok', false, 'reason', 'device does not hold this bus');
  end if;

  insert into public.trips (bus_id, route_id, origin_id, destination_id)
  values (p_bus_id, p_route_id, p_origin_id, p_destination_id)
  returning id into new_id;

  return jsonb_build_object('ok', true, 'trip_id', new_id);
end;
$$;

-- ----------------------------------------------------------------- end_trip
-- Closes the most recent open leg for this bus.
create or replace function public.end_trip(
  p_bus_id    text,
  p_device_id text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  holder    text;
  closed_id bigint;
begin
  select device_id into holder from public.bus_claims where bus_id = p_bus_id;
  if holder is null or holder <> p_device_id then
    return jsonb_build_object('ok', false, 'reason', 'device does not hold this bus');
  end if;

  update public.trips
     set arrived_at = now()
   where id = (
     select id from public.trips
      where bus_id = p_bus_id and arrived_at is null
      order by departed_at desc
      limit 1
   )
  returning id into closed_id;

  return jsonb_build_object('ok', closed_id is not null, 'trip_id', closed_id);
end;
$$;

grant execute on function public.start_trip(text, text, text, text, text)
  to anon, authenticated;
grant execute on function public.end_trip(text, text) to anon, authenticated;

-- Daily rollup for the tracker's analytics screen.
create or replace view public.bus_day_summary as
select
  bus_id,
  (departed_at at time zone 'Asia/Kolkata')::date as service_date,
  count(*)                                        as trips,
  count(*) filter (where arrived_at is null)      as incomplete_trips,
  min(departed_at)                                as first_departure,
  max(coalesce(arrived_at, departed_at))          as last_activity,
  avg(arrived_at - departed_at) filter (where arrived_at is not null)
                                                  as avg_trip_duration
from public.trips
group by bus_id, service_date;
