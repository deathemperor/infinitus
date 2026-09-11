import { InfinitusEventRow, type InfinitusEvent } from "@t3tools/contracts/infinitus";
import * as Schema from "effect/Schema";

/**
 * The Activity page's read model (#659): the pop-out's Activity pane — the
 * app's event log, newest first. The page reads `events --limit 100` once
 * and then folds in the deltas the snapshot subscription already carries
 * (`snapshot.events`, deduped by id), so it never polls on its own.
 */

/** One line of the log, always with an id: the app's own when the row has
    one (native #630), else `<at>#<index>` the way the server names them. */
export interface ActivityRow {
  readonly id: string;
  readonly at: string;
  readonly kind: string;
  readonly icon: string;
  readonly text: string;
}

/** The durable log's vocabulary, as short chips; `other` shows none. */
export const ACTIVITY_KIND_LABELS: Readonly<Record<string, string>> = {
  switch: "switch",
  limit: "limit",
  revival: "revival",
  resume: "resume",
  nudge: "nudge",
  team: "team",
  "team-control": "team",
  hook: "hook",
  pairing: "pairing",
};

/** The engine poller's two lines a minute — `poll` and `no switch — <reason>`
    — which bury the switches, tunnel and pairing events the page exists for
    (#696). Native logs every engine event other than switch, all-exhausted
    and session-resumed as kind `other` (AppModel.eventKind, native 273b1f848),
    so the text decides; the icon cannot, since `hand.raised` is also the
    "session is waiting for an answer" row. */
export function isPollRow(row: Pick<ActivityRow, "kind" | "text">): boolean {
  return row.kind === "other" && (row.text === "poll" || row.text.startsWith("no switch"));
}

const decodeRows = Schema.decodeUnknownOption(Schema.Array(InfinitusEventRow));

/** The `events` reply as rows, or null for anything else. */
export function decodeEventRows(result: unknown): ReadonlyArray<InfinitusEventRow> | null {
  const decoded = decodeRows(result);
  return decoded._tag === "Some" ? decoded.value : null;
}

function rowOf(row: InfinitusEventRow, index: number): ActivityRow {
  return {
    id: row.id ?? `${row.at}#${index}`,
    at: row.at,
    kind: row.kind ?? "other",
    icon: row.icon,
    text: row.text,
  };
}

/**
 * The log to draw: the initial rows (oldest first, as the verb answers) plus
 * every delta seen since, one line per id, newest first. Ties on `at` keep
 * the later-logged line on top.
 */
export function activityRows(
  initial: ReadonlyArray<InfinitusEventRow>,
  deltas: ReadonlyArray<InfinitusEvent>,
): ReadonlyArray<ActivityRow> {
  const byId = new Map<string, { row: ActivityRow; order: number }>();
  let order = 0;
  for (const [index, row] of initial.entries()) {
    const activity = rowOf(row, index);
    if (!byId.has(activity.id)) byId.set(activity.id, { row: activity, order: order++ });
  }
  for (const [index, delta] of deltas.entries()) {
    const activity = rowOf(delta, initial.length + index);
    if (!byId.has(activity.id)) byId.set(activity.id, { row: activity, order: order++ });
  }
  return Array.from(byId.values())
    .sort((a, b) => b.row.at.localeCompare(a.row.at) || b.order - a.order)
    .map((entry) => entry.row);
}
