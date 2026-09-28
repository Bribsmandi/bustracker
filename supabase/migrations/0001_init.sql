-- Campus Bus Tracker — initial schema
-- One row per bus, holding its latest known position. The publisher app upserts;
-- the tracker app reads + subscribes to realtime changes.

create table if not exists public.bus_positions (
  bus_id     text primary key,           -- matches ids in data/buses.json (bus1, ac_mbh, ...)
  lat        double precision not null,
  lng        double precision not null,
  speed      double precision,           -- metres/second, from device GPS (nullable)
  heading    double precision,           -- degrees 0-360 from GPS (nullable; tracker also derives from route)
  route_id   text,                        -- optional: route the bus is currently on (matches data/routes.json)
  updated_at timestamptz not null default now()
);

-- Keep updated_at fresh on every write, even if the client forgets to send it.
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_bus_positions_touch on public.bus_positions;
create trigger trg_bus_positions_touch
  before insert or update on public.bus_positions
  for each row execute function public.touch_updated_at();

-- Row Level Security. This is a public campus app with no login, so anon may
-- read all positions and write positions. Tighten later if you add driver auth.
alter table public.bus_positions enable row level security;

drop policy if exists "anon read bus positions"   on public.bus_positions;
drop policy if exists "anon insert bus positions"  on public.bus_positions;
drop policy if exists "anon update bus positions"  on public.bus_positions;

create policy "anon read bus positions"  on public.bus_positions
  for select using (true);

create policy "anon insert bus positions" on public.bus_positions
  for insert with check (true);

create policy "anon update bus positions" on public.bus_positions
  for update using (true) with check (true);

-- Broadcast INSERT/UPDATE/DELETE to subscribed tracker clients.
alter publication supabase_realtime add table public.bus_positions;
