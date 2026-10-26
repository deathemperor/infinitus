import type { OrchestrationV2ProviderTurn, OrchestrationV2TurnItem } from "@infinitus/contracts";

/**
 * Fork (#834, #927): the tool calls of a provider turn, counted on the normalized turn items,
 * provider-agnostic. The ingestor stamps the count on the terminal `provider-turn.updated` so the
 * rollup never needs the items: a client's bounded snapshot holds only a recent window of them.
 */
export const TOOL_CALL_TURN_ITEM_TYPES: ReadonlySet<OrchestrationV2TurnItem["type"]> = new Set<
  OrchestrationV2TurnItem["type"]
>(["command_execution", "file_change", "file_search", "web_search", "dynamic_tool", "subagent"]);

export const TERMINAL_PROVIDER_TURN_STATUSES: ReadonlySet<OrchestrationV2ProviderTurn["status"]> =
  new Set<OrchestrationV2ProviderTurn["status"]>([
    "completed",
    "interrupted",
    "failed",
    "cancelled",
  ]);

/** Distinct tool items of the turn, whatever their status. */
export function countProviderTurnToolCalls(
  items: ReadonlyArray<Pick<OrchestrationV2TurnItem, "id" | "type" | "providerTurnId">>,
  providerTurnId: OrchestrationV2ProviderTurn["id"],
): number {
  const ids = new Set<string>();
  for (const item of items) {
    if (item.providerTurnId === providerTurnId && TOOL_CALL_TURN_ITEM_TYPES.has(item.type)) {
      ids.add(item.id);
    }
  }
  return ids.size;
}
