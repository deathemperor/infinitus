import type { OrchestrationQueuedTurn } from "@t3tools/contracts";
import { ArrowDownIcon, ArrowUpIcon, ClockIcon, PenLineIcon, SendIcon, XIcon } from "lucide-react";
import { memo } from "react";

import { Button } from "~/components/ui/button";
import { ComposerBanner } from "./ComposerBanner";
import { queuedTurnSnippet } from "./composerSendQueue.logic";

/**
 * The messages the server holds for this thread until its turn finishes
 * (#270 F, #806), under the composer, in send order. Each row can leave now
 * (steer), go back into the composer for editing, move within the queue, or
 * be dropped.
 */
export const ComposerSendQueue = memo(function ComposerSendQueue(props: {
  entries: ReadonlyArray<OrchestrationQueuedTurn>;
  isRunning: boolean;
  onSendNow: (entry: OrchestrationQueuedTurn) => void;
  onEdit: (entry: OrchestrationQueuedTurn) => void;
  onMove: (entry: OrchestrationQueuedTurn, direction: "earlier" | "later") => void;
  onRemove: (entry: OrchestrationQueuedTurn) => void;
}) {
  const { entries, isRunning, onSendNow, onEdit, onMove, onRemove } = props;
  if (entries.length === 0) return null;
  return (
    <ComposerBanner.Root data-composer-send-queue="true" className="mt-1.5">
      <ComposerBanner.Row>
        <ComposerBanner.Icon>
          <ClockIcon />
        </ComposerBanner.Icon>
        <ComposerBanner.Content className="text-muted-foreground">
          {isRunning ? "Sends when this turn finishes" : "Sending when the thread is idle"}
        </ComposerBanner.Content>
        <ComposerBanner.Actions>
          <ComposerBanner.Count>{entries.length}</ComposerBanner.Count>
        </ComposerBanner.Actions>
      </ComposerBanner.Row>
      <ComposerBanner.Children render={<ul role="list" />} aria-label="Queued messages">
        {entries.map((entry, index) => {
          const snippet = queuedTurnSnippet(entry);
          return (
            <ComposerBanner.Row
              render={<li />}
              key={entry.queueId}
              data-queued-message={entry.queueId}
            >
              <ComposerBanner.Icon />
              <ComposerBanner.Content>
                <span className="min-w-0 flex-1 truncate text-foreground/80">{snippet}</span>
              </ComposerBanner.Content>
              <ComposerBanner.Actions>
                {entries.length > 1 ? (
                  <>
                    <Button
                      size="icon-xs"
                      variant="ghost"
                      disabled={index === 0}
                      aria-label={`Send earlier: ${snippet}`}
                      onPointerDown={(event) => event.preventDefault()}
                      onClick={() => onMove(entry, "earlier")}
                    >
                      <ArrowUpIcon />
                    </Button>
                    <Button
                      size="icon-xs"
                      variant="ghost"
                      disabled={index === entries.length - 1}
                      aria-label={`Send later: ${snippet}`}
                      onPointerDown={(event) => event.preventDefault()}
                      onClick={() => onMove(entry, "later")}
                    >
                      <ArrowDownIcon />
                    </Button>
                  </>
                ) : null}
                <Button
                  size="icon-xs"
                  variant="ghost"
                  aria-label={`Edit queued message: ${snippet}`}
                  onPointerDown={(event) => event.preventDefault()}
                  onClick={() => onEdit(entry)}
                >
                  <PenLineIcon />
                </Button>
                <Button
                  size="icon-xs"
                  variant="ghost"
                  aria-label={`Send now: ${snippet}`}
                  onPointerDown={(event) => event.preventDefault()}
                  onClick={() => onSendNow(entry)}
                >
                  <SendIcon />
                </Button>
                <Button
                  size="icon-xs"
                  variant="ghost"
                  aria-label={`Remove queued message: ${snippet}`}
                  onPointerDown={(event) => event.preventDefault()}
                  onClick={() => onRemove(entry)}
                >
                  <XIcon />
                </Button>
              </ComposerBanner.Actions>
            </ComposerBanner.Row>
          );
        })}
      </ComposerBanner.Children>
    </ComposerBanner.Root>
  );
});
