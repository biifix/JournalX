-- JournalX initial schema (MVP: futures, manual entry, single user, multi-user ready)
-- Design notes:
--   * Trades own one or more executions (fills). P&L is always derived, never stored.
--   * Manual entry creates one entry fill + one exit fill; broker sync later just inserts more fills.
--   * Every table carries user_id and is protected by RLS.
--   * All timestamps are timestamptz (UTC). Display in exchange time (America/Chicago) in the app.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- instruments: global seed rows (user_id is null) + user-defined rows
-- ---------------------------------------------------------------------------
create table public.instruments (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid references auth.users (id) on delete cascade,  -- null = global/seeded
  symbol      text not null,
  name        text not null,
  exchange    text,
  tick_size   numeric(18, 8) not null check (tick_size > 0),
  tick_value  numeric(18, 8) not null check (tick_value > 0),   -- currency value of one tick, per contract
  currency    text not null default 'USD',
  created_at  timestamptz not null default now()
);

create unique index instruments_symbol_uniq
  on public.instruments (coalesce(user_id, '00000000-0000-0000-0000-000000000000'::uuid), symbol);

-- ---------------------------------------------------------------------------
-- tags: setups and mistakes
-- ---------------------------------------------------------------------------
create table public.tags (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users (id) on delete cascade default auth.uid(),
  kind        text not null check (kind in ('setup', 'mistake')),
  name        text not null check (length(trim(name)) > 0),
  created_at  timestamptz not null default now(),
  unique (user_id, kind, name),
  unique (id, user_id)
);

-- ---------------------------------------------------------------------------
-- trades
-- ---------------------------------------------------------------------------
create table public.trades (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null references auth.users (id) on delete cascade default auth.uid(),
  instrument_id       uuid not null references public.instruments (id),
  direction           text not null check (direction in ('long', 'short')),
  planned_stop_price  numeric(18, 8),                    -- optional; enables R-multiple
  rating              smallint check (rating between 1 and 5),  -- execution quality, self-assessed
  notes               text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (id, user_id)
);

create index trades_user_idx on public.trades (user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- executions (fills)
-- ---------------------------------------------------------------------------
create table public.executions (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null default auth.uid(),
  trade_id     uuid not null,
  side         text not null check (side in ('buy', 'sell')),
  qty          integer not null check (qty > 0),
  price        numeric(18, 8) not null check (price > 0),
  fee          numeric(18, 8) not null default 0 check (fee >= 0),  -- total fees for this fill
  executed_at  timestamptz not null,
  created_at   timestamptz not null default now(),
  -- composite FK guarantees an execution belongs to a trade owned by the same user
  foreign key (trade_id, user_id) references public.trades (id, user_id) on delete cascade
);

create index executions_trade_idx on public.executions (trade_id);
create index executions_user_time_idx on public.executions (user_id, executed_at);

-- ---------------------------------------------------------------------------
-- trade_tags (many-to-many)
-- ---------------------------------------------------------------------------
create table public.trade_tags (
  trade_id  uuid not null,
  tag_id    uuid not null,
  user_id   uuid not null default auth.uid(),
  primary key (trade_id, tag_id),
  foreign key (trade_id, user_id) references public.trades (id, user_id) on delete cascade,
  foreign key (tag_id, user_id)   references public.tags   (id, user_id) on delete cascade
);

-- ---------------------------------------------------------------------------
-- daily notes
-- ---------------------------------------------------------------------------
create table public.daily_notes (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users (id) on delete cascade default auth.uid(),
  note_date   date not null,
  note        text not null default '',
  mood        smallint check (mood between 1 and 5),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (user_id, note_date)
);

-- ---------------------------------------------------------------------------
-- updated_at trigger
-- ---------------------------------------------------------------------------
create function public.set_updated_at() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger trades_updated_at before update on public.trades
  for each row execute function public.set_updated_at();
create trigger daily_notes_updated_at before update on public.daily_notes
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------
alter table public.instruments  enable row level security;
alter table public.tags         enable row level security;
alter table public.trades       enable row level security;
alter table public.executions   enable row level security;
alter table public.trade_tags   enable row level security;
alter table public.daily_notes  enable row level security;

-- instruments: read global + own; write own only
create policy instruments_select on public.instruments for select to authenticated
  using (user_id is null or user_id = (select auth.uid()));
create policy instruments_insert on public.instruments for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy instruments_update on public.instruments for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy instruments_delete on public.instruments for delete to authenticated
  using (user_id = (select auth.uid()));

-- owner-only tables
create policy tags_owner        on public.tags        for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy trades_owner      on public.trades      for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy executions_owner  on public.executions  for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy trade_tags_owner  on public.trade_tags  for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy daily_notes_owner on public.daily_notes for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- trade_summary: derived P&L per trade (average-price method)
--   point_value = tick_value / tick_size
--   gross_pnl   = sign * (avg_exit - avg_entry) * closed_qty * point_value   (sign: long=+1, short=-1)
--   net_pnl     = gross_pnl - total fees
--   risk        = |avg_entry - planned_stop| * entry_qty * point_value
--   r_multiple  = net_pnl / risk
-- P&L fields are null until the trade is fully closed (entry_qty = exit_qty).
-- ---------------------------------------------------------------------------
create view public.trade_summary
with (security_invoker = true) as
with fills as (
  select
    e.trade_id, e.qty, e.price, e.fee, e.executed_at,
    (e.side = case t.direction when 'long' then 'buy' else 'sell' end) as is_entry
  from public.executions e
  join public.trades t on t.id = e.trade_id
),
agg as (
  select
    trade_id,
    coalesce(sum(qty) filter (where is_entry), 0)       as entry_qty,
    coalesce(sum(qty) filter (where not is_entry), 0)   as exit_qty,
    sum(qty * price) filter (where is_entry)
      / nullif(sum(qty) filter (where is_entry), 0)     as avg_entry,
    sum(qty * price) filter (where not is_entry)
      / nullif(sum(qty) filter (where not is_entry), 0) as avg_exit,
    sum(fee)                                            as fees,
    min(executed_at)                                    as opened_at,
    max(executed_at) filter (where not is_entry)        as closed_at
  from fills
  group by trade_id
),
calc as (
  select
    t.id, t.user_id, t.instrument_id, t.direction, t.planned_stop_price, t.rating, t.notes,
    t.created_at, t.updated_at,
    i.symbol,
    (i.tick_value / i.tick_size) as point_value,
    a.entry_qty, a.exit_qty, a.avg_entry, a.avg_exit,
    coalesce(a.fees, 0) as fees,
    a.opened_at, a.closed_at,
    (a.entry_qty > 0 and a.entry_qty = a.exit_qty) as is_closed,
    case t.direction when 'long' then 1 else -1 end as sign
  from public.trades t
  join public.instruments i on i.id = t.instrument_id
  left join agg a on a.trade_id = t.id
)
select
  id, user_id, instrument_id, symbol, direction, planned_stop_price, rating, notes,
  created_at, updated_at,
  point_value, entry_qty, exit_qty, avg_entry, avg_exit, fees, opened_at,
  case when is_closed then closed_at end as closed_at,
  coalesce(is_closed, false) as is_closed,
  case when is_closed then sign * (avg_exit - avg_entry) * entry_qty * point_value end as gross_pnl,
  case when is_closed then sign * (avg_exit - avg_entry) * entry_qty * point_value - fees end as net_pnl,
  case when planned_stop_price is not null and entry_qty > 0
       then abs(avg_entry - planned_stop_price) * entry_qty * point_value end as risk_amount,
  case when is_closed and planned_stop_price is not null
            and abs(avg_entry - planned_stop_price) > 0
       then (sign * (avg_exit - avg_entry) * entry_qty * point_value - fees)
            / (abs(avg_entry - planned_stop_price) * entry_qty * point_value) end as r_multiple
from calc;

-- ---------------------------------------------------------------------------
-- Seed: common CME futures (verify against current CME contract specs before relying on them)
-- ---------------------------------------------------------------------------
insert into public.instruments (symbol, name, exchange, tick_size, tick_value) values
  ('ES',  'E-mini S&P 500',          'CME',   0.25, 12.50),
  ('MES', 'Micro E-mini S&P 500',    'CME',   0.25,  1.25),
  ('NQ',  'E-mini Nasdaq-100',       'CME',   0.25,  5.00),
  ('MNQ', 'Micro E-mini Nasdaq-100', 'CME',   0.25,  0.50),
  ('RTY', 'E-mini Russell 2000',     'CME',   0.10,  5.00),
  ('M2K', 'Micro E-mini Russell 2000','CME',  0.10,  0.50),
  ('YM',  'E-mini Dow',              'CBOT',  1.00,  5.00),
  ('MYM', 'Micro E-mini Dow',        'CBOT',  1.00,  0.50),
  ('CL',  'Crude Oil',               'NYMEX', 0.01, 10.00),
  ('MCL', 'Micro Crude Oil',         'NYMEX', 0.01,  1.00),
  ('GC',  'Gold',                    'COMEX', 0.10, 10.00),
  ('MGC', 'Micro Gold',              'COMEX', 0.10,  1.00);
