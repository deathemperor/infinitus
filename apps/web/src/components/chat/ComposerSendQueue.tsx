import { ArrowDownIcon, ArrowUpIcon, ClockIcon, PenLineIcon, SendIcon, XIcon } from "lucide-react";
import { memo } from "react";

import { Button } from "~/components/ui/button";
import { type PromptStashEntry } from "../../promptStashStore";
import { ComposerBanner } from "./ComposerBanner";
import { queuedEntrySnippet } from "./composerSendQueue.logic";

/**
 * The messages waiting for this thread's turn to finish (#270 F), under the
 * composer. Each row can leave now (steer), go back into the composer for
 * editing, move within the queue, or be dropped.
 */
export const ComposerSendQueue = memo(function ComposerSendQueue(props: {
  entries: ReadonlyArray<PromptStashEntry>;
  isRunning: boolean;
  onSendNow: (entry: PromptStashEntry) => void;
  onEdit: (entry: PromptStashEntry) => void;
  onMove: (entry: PromptStashEntry, direction: "earlier" | "later") => void;
  onRemove: (entry: PromptStashEntry) => void;
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
          const snippet = queuedEntrySnippet(entry);
          const saving = entry.pendingImageCount ? entry.pendingImageCount > 0 : false;
          return (
            <ComposerBanner.Row render={<li />} key={entry.id} data-queued-message={entry.id}>
              <ComposerBanner.Icon />
              <ComposerBanner.Content>
                <span className="min-w-0 flex-1 truncate text-foreground/80">{snippet}</span>
              </ComposerBanner.Content>
              <ComposerBanner.Actions>
                {saving ? <span className="shrink-0 text-muted-foreground">saving…</span> : null}
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
                  disabled={saving}
                  aria-label={`Edit queued message: ${snippet}`}
                  onPointerDown={(event) => event.preventDefault()}
                  onClick={() => onEdit(entry)}
                >
                  <PenLineIcon />
                </Button>
                <Button
                  size="icon-xs"
                  variant="ghost"
                  disabled={saving}
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
