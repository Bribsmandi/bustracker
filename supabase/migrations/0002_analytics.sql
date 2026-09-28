-- Campus Bus Tracker — analytics: stop arrival/departure log.
-- The publisher (bus phone) writes one 'arrival' row when it enters a stop's
-- radius and one 'departure' row when it leaves, so we can reconstruct where
-- each bus was, when, and how long it dwelled at terminals.

create table if not exists public.bus_stop_events (
  id      bigint generated always as identity primary key,
  bus_id  text not null,
  stop_id text not null,
  event   text not null default 'arrival',   -- 'arrival' | 'departure'
  speed   double precision,                   -- m/s at the moment of the event
  at      timestamptz not null default now()
);

create index if not exists idx_bus_stop_events_bus_at
  on public.bus_stop_events (bus_id, at desc);
create index if not exists idx_bus_stop_events_stop_at
  on public.bus_stop_events (stop_id, at desc);

alter table public.bus_stop_events enable row level security;

drop policy if exists "anon read stop events"   on public.bus_stop_events;
drop policy if exists "anon insert stop events"  on public.bus_stop_events;

create policy "anon read stop events"  on public.bus_stop_events
  for select using (true);

create policy "anon insert stop events" on public.bus_stop_events
  for insert with check (true);

-- Convenience view: latest event per bus (where each bus was last seen).
create or replace view public.bus_last_stop as
select distinct on (bus_id)
  bus_id, stop_id, event, at
from public.bus_stop_events
order by bus_id, at desc;
