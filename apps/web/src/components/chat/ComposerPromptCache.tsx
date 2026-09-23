import type { OrchestrationSession, ThreadUsageRollup } from "@infinitus/contracts";
import { TimerIcon } from "lucide-react";
import {
  promptCacheNextChangeMs,
  promptCacheRemainingLabel,
  promptCacheState,
  promptCacheWriterAlive,
} from "@infinitus/shared/threadUsage";
import { useEffect, useState } from "react";

import { cn } from "~/lib/utils";
import { Tooltip, TooltipPopup, TooltipTrigger } from "../ui/tooltip";
import { promptCacheDetail } from "./composerPromptCache.logic";

/**
 * Fork: the composer frame's border takes the prompt cache's colour from
 * the footer label below it (`:has()`), so the minute tick re-renders only
 * the label, never the composer.
 */
export const PROMPT_CACHE_FRAME_CLASS_NAME =
  "has-data-[prompt-cache=warm]:ring-1 has-data-[prompt-cache=warm]:ring-inset has-data-[prompt-cache=warm]:ring-success/60 has-data-[prompt-cache=expiring]:ring-1 has-data-[prompt-cache=expiring]:ring-inset has-data-[prompt-cache=expiring]:ring-warning/70";

/**
 * Fork: how long the thread's prompt cache stays warm, in the composer
 * footer, so the user can tell whether the next message reads the context
 * from cache or re-writes it. Drawn only when the last turn's provider
 * reported a TTL (Claude); the caller hides it while a turn runs, since
 * every call of a running turn restarts the clock.
 */
export function ComposerPromptCache(props: {
  usage: ThreadUsageRollup | undefined;
  session: OrchestrationSession | null | undefined;
  compact: boolean;
  contextTokens: number | null;
}) {
  const cacheExpiresAt = props.usage?.cacheExpiresAt;
  if (props.usage === undefined || cacheExpiresAt === undefined) return null;
  // Keyed so a new turn's expiry starts from a fresh clock.
  return (
    <PromptCacheLabel
      key={cacheExpiresAt}
      cacheExpiresAt={cacheExpiresAt}
      lastTurnAt={props.usage.lastTurnAt}
      sessionAlive={promptCacheWriterAlive(props.session, props.usage.lastTurnAt)}
      compact={props.compact}
      contextTokens={props.contextTokens}
    />
  );
}

function PromptCacheLabel(props: {
  cacheExpiresAt: string;
  lastTurnAt: string;
  sessionAlive: boolean;
  compact: boolean;
  contextTokens: number | null;
}) {
  const [nowMs, setNowMs] = useState(Date.now);
  useEffect(() => {
    // A session that ended reads cold until expiry, so nothing to tick for.
    if (!props.sessionAlive) return;
    let timer: number | undefined;
    const arm = () => {
      const delayMs = promptCacheNextChangeMs(props.cacheExpiresAt, Date.now());
      if (delayMs === null) return;
      timer = window.setTimeout(() => {
        setNowMs(Date.now());
        arm();
      }, delayMs);
    };
    arm();
    return () => window.clearTimeout(timer);
  }, [props.cacheExpiresAt, props.sessionAlive]);

  const state = promptCacheState(props, nowMs, props.sessionAlive);
  if (state === null) return null;
  const label =
    state.kind === "cold"
      ? state.reason === "expired"
        ? "expired"
        : "cold"
      : promptCacheRemainingLabel(state.remainingMs);
  return (
    <Tooltip>
      <TooltipTrigger
        render={
          <span
            data-prompt-cache={state.kind}
            data-testid="composer-prompt-cache"
            className="flex h-7 shrink-0 cursor-default items-center gap-1 px-1.5 text-muted-foreground/70 text-xs"
          />
        }
      >
        <TimerIcon
          aria-hidden="true"
          className={cn(
            "size-3.5 shrink-0",
            state.kind === "warm" && "text-success",
            state.kind === "expiring" && "text-warning",
          )}
        />
        <span className="sr-only">Prompt cache</span>
        {props.compact ? null : <span className="tabular-nums">{label}</span>}
      </TooltipTrigger>
      <TooltipPopup side="top" className="max-w-64">
        {promptCacheDetail(state, props.contextTokens)}
      </TooltipPopup>
    </Tooltip>
  );
}
