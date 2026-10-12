import { ProviderTurnId, TurnItemId } from "@infinitus/contracts";
import { describe, expect, it } from "vite-plus/test";

import { countProviderTurnToolCalls, TOOL_CALL_TURN_ITEM_TYPES } from "./providerTurnToolCalls.ts";

describe("countProviderTurnToolCalls (#834, #927)", () => {
  const turn = ProviderTurnId.make("provider-turn-1");
  const other = ProviderTurnId.make("provider-turn-2");
  const item = (id: string, type: string, providerTurnId = turn) =>
    ({ id: TurnItemId.make(id), type, providerTurnId }) as Parameters<
      typeof countProviderTurnToolCalls
    >[0][number];

  it("counts the turn's distinct tool items, whatever their status, and nothing else", () => {
    expect(
      countProviderTurnToolCalls(
        [
          item("cmd", "command_execution"),
          item("cmd", "command_execution"),
          item("edit", "file_change"),
          item("sub", "subagent"),
          item("text", "assistant_message"),
          item("reason", "reasoning"),
          item("elsewhere", "web_search", other),
        ],
        turn,
      ),
    ).toBe(3);
    expect(countProviderTurnToolCalls([], turn)).toBe(0);
  });

  it("names every tool-shaped item type the adapters normalize", () => {
    expect([...TOOL_CALL_TURN_ITEM_TYPES].sort()).toEqual([
      "command_execution",
      "dynamic_tool",
      "file_change",
      "file_search",
      "subagent",
      "web_search",
    ]);
  });
});
