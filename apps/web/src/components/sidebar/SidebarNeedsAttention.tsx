import { useAtomValue } from "@effect/atom-react";
import { EnvironmentId, type ScopedThreadRef } from "@t3tools/contracts";
import type { InfinitusHeldThread } from "@t3tools/contracts/infinitus";
import { scopeThreadRef, scopedThreadKey } from "@t3tools/client-runtime/environment";
import * as Option from "effect/Option";
import { AsyncResult, Atom } from "effect/unstable/reactivity";
import { ChevronDownIcon } from "lucide-react";
import { useMemo, type MouseEvent as ReactMouseEvent } from "react";

import { useNowMinute } from "../../hooks/useNowMinute";
import { infinitusEnvironment } from "../../state/infinitus";
import { formatElapsedDurationLabel } from "../../timestampFormat";
import type { SidebarThreadSummary } from "../../types";
import { cn } from "~/lib/utils";
import { collectNeedsAttention, type NeedsAttentionStatus } from "./sidebarNeedsAttention.logic";

/**
 * Every Infinitus environment's holds in one read, keyed by the sorted id
 * list so the atom is shared across renders and with the rows' own
 * `useInfinitusHeldSummary` subscriptions (same family, same stream).
 */
const holdsByEnvironmentAtom = Atom.family((key: string) =>
  Atom.make((get) => {
    const holds = new Map<EnvironmentId, ReadonlyArray<InfinitusHeldThread> | null>();
    for (const id of key.length === 0 ? [] : key.split("\n")) {
      const environmentId = EnvironmentId.make(id);
      holds.set(
        environmentId,
        Option.getOrNull(
          AsyncResult.value(get(infinitusEnvironment.holds({ environmentId, input: {} }))),
        ),
      );
    }
    return holds;
  }).pipe(Atom.withLabel(`sidebar-needs-attention:holds:${key}`)),
);

// Same words and hues as the rows' status pills, so a thread reads the same
// here and in its place in the list.
const STATUS_LABEL: Record<NeedsAttentionStatus, { label: string; className: string }> = {
  approval: { label: "Approval", className: "text-amber-700 dark:text-amber-300" },
  input: { label: "Input", className: "text-indigo-600 dark:text-indigo-300" },
  held: { label: "Held", className: "text-muted-foreground" },
  limited: { label: "Limit", className: "text-muted-foreground" },
};

/**
 * Fork (#269 D): the threads blocked on the user, above the list, across
 * every project and environment. Pure presentation over the same status
 * resolution the rows and the next-attention key use; hidden when nothing
 * waits. Clicking a row is the same click as on the row below.
 */
export function SidebarNeedsAttention(props: {
  readonly threads: ReadonlyArray<SidebarThreadSummary>;
  /** Sorted; only these environments have holds to read. */
  readonly infinitusEnvironmentIds: ReadonlyArray<EnvironmentId>;
  readonly routeThreadKey: string | null;
  readonly environmentLabelById: ReadonlyMap<EnvironmentId, string>;
  readonly projectDisplayNameByKey: ReadonlyMap<string, string>;
  readonly expanded: boolean;
  readonly onToggle: () => void;
  readonly onThreadClick: (event: ReactMouseEvent, threadRef: ScopedThreadRef) => void;
}) {
  const holdsByEnvironment = useAtomValue(
    holdsByEnvironmentAtom(props.infinitusEnvironmentIds.join("\n")),
  );
  const entries = useMemo(
    () => collectNeedsAttention(props.threads, holdsByEnvironment),
    [holdsByEnvironment, props.threads],
  );
  const nowMinute = useNowMinute();
  if (entries.length === 0) return null;
  const nowMs = Date.parse(nowMinute);
  const showEnvironment = props.environmentLabelById.size > 1;
  return (
    <section
      aria-label="Needs attention"
      data-testid="sidebar-needs-attention"
      className="mx-0.5 mb-1"
    >
      <button
        type="button"
        onClick={props.onToggle}
        aria-expanded={props.expanded}
        data-testid="sidebar-needs-attention-toggle"
        className="flex h-8 w-full cursor-pointer items-center gap-2 px-2 text-left text-xs font-medium text-amber-700 dark:text-amber-300"
      >
        <span className="shrink-0">
          {props.expanded ? "Needs attention" : `Needs attention (${entries.length})`}
        </span>
        <span aria-hidden className="h-px min-w-2 flex-1 bg-amber-500/25 dark:bg-amber-400/20" />
        <ChevronDownIcon
          aria-hidden
          className={cn("size-3 shrink-0 transition-transform", props.expanded && "rotate-180")}
        />
      </button>
      {props.expanded ? (
        <ul role="list" className="flex flex-col gap-px">
          {entries.map((entry) => {
            const threadRef = scopeThreadRef(entry.thread.environmentId, entry.thread.id);
            const threadKey = scopedThreadKey(threadRef);
            const status = STATUS_LABEL[entry.status];
            const projectName =
              props.projectDisplayNameByKey.get(
                `${entry.thread.environmentId}:${entry.thread.projectId}`,
              ) ?? null;
            const environmentLabel = showEnvironment
              ? (props.environmentLabelById.get(entry.thread.environmentId) ?? null)
              : null;
            const where = [projectName, environmentLabel].filter(
              (part): part is string => part !== null,
            );
            const waited = formatElapsedDurationLabel(entry.since, nowMs);
            return (
              <li key={threadKey} className="list-none" data-needs-attention-thread={threadKey}>
                <button
                  type="button"
                  onClick={(event) => props.onThreadClick(event, threadRef)}
                  aria-current={props.routeThreadKey === threadKey ? "page" : undefined}
                  className={cn(
                    "flex w-full cursor-pointer flex-col gap-0.5 rounded-md px-2.5 py-1.5 text-left hover:bg-sidebar-row-hover",
                    props.routeThreadKey === threadKey && "bg-sidebar-row-hover",
                  )}
                >
                  <span className="flex min-w-0 items-center gap-2 text-sm">
                    <span className={cn("shrink-0 text-xs font-medium", status.className)}>
                      {status.label}
                    </span>
                    <span className="min-w-0 flex-1 truncate text-sidebar-foreground">
                      {entry.thread.title}
                    </span>
                    {waited.length > 0 ? (
                      <span className="shrink-0 text-xs text-sidebar-muted-foreground/70">
                        {waited}
                      </span>
                    ) : null}
                  </span>
                  {where.length > 0 || entry.summary !== null ? (
                    <span className="min-w-0 truncate text-xs text-sidebar-muted-foreground/70">
                      {entry.summary ?? where.join(" · ")}
                    </span>
                  ) : null}
                </button>
              </li>
            );
          })}
        </ul>
      ) : null}
    </section>
  );
}
