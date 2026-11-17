# JournalX data model

Schema lives in `supabase/migrations/20261118000000_init_schema.sql`.

## Tables

| Table | Purpose |
|---|---|
| `instruments` | Futures contracts. `user_id` null = global seed; otherwise user-defined. Stores `tick_size` and `tick_value`. |
| `trades` | One row per round trip: direction, optional planned stop, rating, notes. |
| `executions` | Fills belonging to a trade (`buy`/`sell`, qty, price, fee, time). Source of truth for P&L. |
| `tags` | User setups and mistakes (`kind`). |
| `trade_tags` | Many-to-many link between trades and tags. |
| `daily_notes` | One note (and optional mood) per user per date. |
| `trade_summary` (view) | Derived per-trade P&L, fees, R-multiple. `security_invoker`, so RLS applies. |

## P&L formulas (average-price method)

- `point_value = tick_value / tick_size`
- Entry side: `buy` for long, `sell` for short. Exit side is the opposite.
- `avg_entry`, `avg_exit` = quantity-weighted average price of entry/exit fills.
- A trade is **closed** when `entry_qty = exit_qty`. P&L fields are null until then.
- `gross_pnl = sign * (avg_exit - avg_entry) * qty * point_value` (sign: long +1, short -1)
- `net_pnl = gross_pnl - sum(fees)`
- `risk_amount = |avg_entry - planned_stop| * entry_qty * point_value`
- `r_multiple = net_pnl / risk_amount`

### Worked examples (use these as unit-test fixtures)

1. ES long, 2 contracts, buy 5000.00, sell 5010.00, fees 5.00 total.
   point_value = 12.50 / 0.25 = 50. gross = 10 * 2 * 50 = 1000. net = 995.
2. MNQ short, 3 contracts, sell 18000.00, buy 18010.00, fees 3.00.
   point_value = 0.50 / 0.25 = 2. gross = -1 * (18010 - 18000) * 3 * 2 = -60. net = -63.
3. ES long with stop 4995.00, entry 5000.00, qty 2, net 995. risk = 5 * 2 * 50 = 500. R = 1.99.
4. Scaled: ES long buy 1 @ 5000, buy 1 @ 5002, sell 2 @ 5010. avg_entry 5001. gross = 9 * 2 * 50 = 900.

## Known limitations (deliberate for the MVP)

- Average-price method only (no FIFO lot matching). Re-entering after full close should be a new trade.
- Over-selling (exit qty > entry qty) leaves a trade open rather than raising an error; the app should validate.
- Foreign keys do not enforce that `trades.instrument_id` points to an instrument the user can see. Validate in the app.
- Fees are stored per fill as a total, not per contract.
- Seeded tick values should be checked against current CME specs.
