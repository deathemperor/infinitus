import { usePrimarySettings } from "../../hooks/useSettings";
import { limitedLine, resetLabelFor } from "../chat/infinitusHoldBanner.logic";
import type { heldEntryFor } from "./infinitusHeld.logic";

/** The held / limited status pill's tooltip: the row's line and, for a limit
    stop, when its window resets (#270 I). A component of its own so only an
    open tooltip reads the timestamp format, never every sidebar row. */
export function HeldTooltipText({ entry }: { readonly entry: ReturnType<typeof heldEntryFor> }) {
  const timestampFormat = usePrimarySettings((settings) => settings.timestampFormat);
  if (entry === null) return null;
  if (entry.kind !== "limited") return entry.summary;
  return limitedLine(entry.summary, resetLabelFor(entry.resetsAt, timestampFormat));
}
