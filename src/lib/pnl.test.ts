import { describe, expect, it } from "vitest";
import { computeTrade } from "./pnl";

const ES = { tickSize: 0.25, tickValue: 12.5 };
const MNQ = { tickSize: 0.25, tickValue: 0.5 };

describe("computeTrade (fixtures from docs/data-model.md)", () => {
  it("1. ES long 2 @ 5000 -> 5010, fees 5", () => {
    const r = computeTrade({
      direction: "long",
      ...ES,
      fills: [
        { side: "buy", qty: 2, price: 5000, fee: 2.5 },
        { side: "sell", qty: 2, price: 5010, fee: 2.5 },
      ],
    });
    expect(r.pointValue).toBe(50);
    expect(r.grossPnl).toBe(1000);
    expect(r.netPnl).toBe(995);
  });

  it("2. MNQ short 3 @ 18000 -> 18010, fees 3", () => {
    const r = computeTrade({
      direction: "short",
      ...MNQ,
      fills: [
        { side: "sell", qty: 3, price: 18000, fee: 1.5 },
        { side: "buy", qty: 3, price: 18010, fee: 1.5 },
      ],
    });
    expect(r.pointValue).toBe(2);
    expect(r.grossPnl).toBe(-60);
    expect(r.netPnl).toBe(-63);
  });

  it("3. R-multiple with planned stop", () => {
    const r = computeTrade({
      direction: "long",
      ...ES,
      plannedStop: 4995,
      fills: [
        { side: "buy", qty: 2, price: 5000, fee: 2.5 },
        { side: "sell", qty: 2, price: 5010, fee: 2.5 },
      ],
    });
    expect(r.riskAmount).toBe(500);
    expect(r.rMultiple).toBeCloseTo(1.99, 2);
  });

  it("4. scaled entry", () => {
    const r = computeTrade({
      direction: "long",
      ...ES,
      fills: [
        { side: "buy", qty: 1, price: 5000, fee: 0 },
        { side: "buy", qty: 1, price: 5002, fee: 0 },
        { side: "sell", qty: 2, price: 5010, fee: 0 },
      ],
    });
    expect(r.avgEntry).toBe(5001);
    expect(r.grossPnl).toBe(900);
  });

  it("open trade has null P&L", () => {
    const r = computeTrade({
      direction: "long",
      ...ES,
      fills: [{ side: "buy", qty: 1, price: 5000, fee: 1 }],
    });
    expect(r.isClosed).toBe(false);
    expect(r.netPnl).toBeNull();
  });
});
