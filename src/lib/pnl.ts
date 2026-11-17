// Average-price P&L, mirroring the `trade_summary` view (docs/data-model.md).

export type Direction = "long" | "short";
export type Side = "buy" | "sell";

export interface Fill {
  side: Side;
  qty: number;
  price: number;
  fee: number;
}

export interface TradeInput {
  direction: Direction;
  tickSize: number;
  tickValue: number;
  plannedStop?: number | null;
  fills: Fill[];
}

export interface TradeResult {
  pointValue: number;
  entryQty: number;
  exitQty: number;
  avgEntry: number | null;
  avgExit: number | null;
  fees: number;
  isClosed: boolean;
  grossPnl: number | null;
  netPnl: number | null;
  riskAmount: number | null;
  rMultiple: number | null;
}

function weightedAvg(fills: Fill[]): number | null {
  const qty = fills.reduce((s, f) => s + f.qty, 0);
  if (qty === 0) return null;
  return fills.reduce((s, f) => s + f.qty * f.price, 0) / qty;
}

export function computeTrade(t: TradeInput): TradeResult {
  const entrySide: Side = t.direction === "long" ? "buy" : "sell";
  const entries = t.fills.filter((f) => f.side === entrySide);
  const exits = t.fills.filter((f) => f.side !== entrySide);

  const pointValue = t.tickValue / t.tickSize;
  const entryQty = entries.reduce((s, f) => s + f.qty, 0);
  const exitQty = exits.reduce((s, f) => s + f.qty, 0);
  const avgEntry = weightedAvg(entries);
  const avgExit = weightedAvg(exits);
  const fees = t.fills.reduce((s, f) => s + f.fee, 0);
  const isClosed = entryQty > 0 && entryQty === exitQty;
  const sign = t.direction === "long" ? 1 : -1;

  const grossPnl =
    isClosed && avgEntry !== null && avgExit !== null
      ? sign * (avgExit - avgEntry) * entryQty * pointValue
      : null;
  const netPnl = grossPnl !== null ? grossPnl - fees : null;

  const stopDist =
    t.plannedStop != null && avgEntry !== null
      ? Math.abs(avgEntry - t.plannedStop)
      : null;
  const riskAmount =
    stopDist !== null && entryQty > 0 ? stopDist * entryQty * pointValue : null;
  const rMultiple =
    netPnl !== null && riskAmount !== null && riskAmount > 0
      ? netPnl / riskAmount
      : null;

  return {
    pointValue,
    entryQty,
    exitQty,
    avgEntry,
    avgExit,
    fees,
    isClosed,
    grossPnl,
    netPnl,
    riskAmount,
    rMultiple,
  };
}
