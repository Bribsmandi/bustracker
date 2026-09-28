-- Campus Bus Tracker — device claims + journey state.
--
-- Two things this adds:
--  1. Only ONE publisher phone may broadcast as a given bus at a time. A claim
--     is held by a device_id and expires once the holder goes quiet, so a
--     phone that dies mid-route doesn't lock the bus forever.
--  2. The bus's current journey (origin -> destination terminal + state), so
--     the tracker knows which direction it is travelling without guessing.

-- ---------------------------------------------------------------- journey cols
alter table public.bus_positions
  add column if not exists device_id     text,
  add column if not exists origin_id     text,
  add column if not exists destination_id text,
  add column if not exists journey_state text;   -- 'outbound' | 'parked' | null

-- ------------------------------------------------------------------- claims
create table if not exists public.bus_claims (
  bus_id     text primary key,
  device_id  text        not null,
  claimed_at timestamptz not null default now(),
  last_seen  timestamptz not null default now()
);

alter table public.bus_claims enable row level security;

drop policy if exists "anon read claims" on public.bus_claims;
create policy "anon read claims" on public.bus_claims for select using (true);
-- No direct anon insert/update: all writes go through the functions below.

-- How long a claim survives without a heartbeat before another phone may take
-- over. Matches the tracker's 5-minute "bus is offline" rule.
create or replace function public.claim_ttl()
returns interval language sql immutable as $$ select interval '5 minutes' $$;

-- ------------------------------------------------------------- claim_bus()
-- Atomically grant the claim. Returns {ok, holder, reason}.
create or replace function public.claim_bus(p_bus_id text, p_device_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  existing public.bus_claims%rowtype;
begin
  if p_bus_id is null or p_device_id is null then
    return jsonb_build_object('ok', false, 'reason', 'missing bus_id or device_id');
  end if;

  -- Lock the row so two phones racing cannot both win.
  select * into existing from public.bus_claims
    where bus_id = p_bus_id for update;

  if not found then
    insert into public.bus_claims (bus_id, device_id) values (p_bus_id, p_device_id);
    return jsonb_build_object('ok', true, 'holder', p_device_id, 'reason', 'claimed');
  end if;

  if existing.device_id = p_device_id then
    update public.bus_claims set last_seen = now() where bus_id = p_bus_id;
    return jsonb_build_object('ok', true, 'holder', p_device_id, 'reason', 'renewed');
  end if;

  -- Someone else holds it — only allow takeover if they've gone quiet.
  if existing.last_seen < now() - public.claim_ttl() then
    update public.bus_claims
       set device_id = p_device_id, claimed_at = now(), last_seen = now()
     where bus_id = p_bus_id;
    return jsonb_build_object('ok', true, 'holder', p_device_id, 'reason', 'taken over from inactive device');
  end if;

  return jsonb_build_object(
    'ok', false,
    'holder', existing.device_id,
    'reason', 'another phone is already publishing as this bus');
end;
$$;

-- ----------------------------------------------------------- release_bus()
create or replace function public.release_bus(p_bus_id text, p_device_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.bus_claims
   where bus_id = p_bus_id and device_id = p_device_id;
  -- Clear the live row so the tracker stops showing a bus nobody is driving.
  delete from public.bus_positions
   where bus_id = p_bus_id and device_id = p_device_id;
  return jsonb_build_object('ok', true);
end;
$$;

-- ------------------------------------------------------- publish_position()
-- The only way to write a position. Rejects a device that does not hold the
-- claim, so a second phone cannot shadow-publish as the same bus.
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
  holder text;
begin
  select device_id into holder from public.bus_claims where bus_id = p_bus_id;

  if holder is null then
    return jsonb_build_object('ok', false, 'reason', 'no active claim — call claim_bus first');
  end if;
  if holder <> p_device_id then
    return jsonb_build_object('ok', false, 'holder', holder,
      'reason', 'another phone holds this bus');
  end if;

  update public.bus_claims set last_seen = now() where bus_id = p_bus_id;

  insert into public.bus_positions as bp
    (bus_id, lat, lng, speed, heading, route_id,
     device_id, origin_id, destination_id, journey_state)
  values
    (p_bus_id, p_lat, p_lng, p_speed, p_heading, p_route_id,
     p_device_id, p_origin_id, p_destination_id, p_journey_state)
  on conflict (bus_id) do update set
    lat = excluded.lat,
    lng = excluded.lng,
    speed = excluded.speed,
    heading = excluded.heading,
    route_id = excluded.route_id,
    device_id = excluded.device_id,
    origin_id = excluded.origin_id,
    destination_id = excluded.destination_id,
    journey_state = excluded.journey_state;

  return jsonb_build_object('ok', true);
end;
$$;

-- Anon may read positions and call the functions, but not write the tables
-- directly — that is what makes the single-publisher rule stick.
drop policy if exists "anon insert bus positions" on public.bus_positions;
drop policy if exists "anon update bus positions" on public.bus_positions;

grant execute on function public.claim_bus(text, text)        to anon, authenticated;
grant execute on function public.release_bus(text, text)      to anon, authenticated;
grant execute on function public.publish_position(
  text, text, double precision, double precision, double precision,
  double precision, text, text, text, text)                    to anon, authenticated;
