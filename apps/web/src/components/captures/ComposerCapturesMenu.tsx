import type { CaptureItem } from "@t3tools/contracts/captures";
import { CheckIcon, CopyIcon, ListTodoIcon, SendIcon, XIcon } from "lucide-react";
import { memo, useCallback, useEffect, useRef, useState } from "react";

import { writeTextToClipboard } from "~/hooks/useCopyToClipboard";
import { cn } from "~/lib/utils";
import { captures } from "~/state/captures";
import { useEnvironmentQuery } from "~/state/query";
import { useAtomCommand } from "~/state/use-atom-command";

import { ComposerBanner } from "../chat/ComposerBanner";
import { toastManager } from "../ui/toast";
import {
  captureApplyFailureMessage,
  captureSnippet,
  captureText,
  orderCaptures,
} from "./captures.logic";
import type { ActiveProjectRef } from "./useCaptures";
import { squashAtomCommandFailure } from "@t3tools/client-runtime/state/runtime";

/**
 * The composer's Captures popover (#433): the project's list, an input that
 * adds on Enter (a multi-line paste is one capture), and per item Send to
 * composer, Copy, done, remove; "Clear done" at the foot. Opened by the
 * shoulder badge, `captures.toggle` or `captures.add`; closed by Escape, a
 * pointer outside, or a Send that landed. Drawn in the composer's anchored
 * layer like the stash menu.
 */
export const ComposerCapturesMenu = memo(function ComposerCapturesMenu(props: {
  project: ActiveProjectRef | null;
  /** Ticks when the input should take focus (`captures.add` with nothing selected). */
  focusInputKey: number;
  /** Puts the text at the end of the composer; false while the composer is busy. */
  onSend: (text: string) => boolean;
  onClose: () => void;
}) {
  const { project, focusInputKey, onSend, onClose } = props;
  const drawerRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const [draft, setDraft] = useState("");
  const query = useEnvironmentQuery(
    project === null
      ? null
      : captures.list({
          environmentId: project.environmentId,
          input: { projectId: project.projectId },
        }),
  );
  const apply = useAtomCommand(captures.apply, { reportFailure: false });
  const list = query.data ?? [];
  const rows = orderCaptures(list);
  const doneCount = list.length - rows.filter((item) => item.doneAt === null).length;

  const run = useCallback(
    async (command: Parameters<typeof apply>[0]["input"]["command"]) => {
      if (project === null) return false;
      const result = await apply({
        environmentId: project.environmentId,
        input: { projectId: project.projectId, command },
      });
      if (result._tag === "Success") return true;
      toastManager.add({
        type: "error",
        title: "Captures not updated",
        description: captureApplyFailureMessage(squashAtomCommandFailure(result)),
      });
      return false;
    },
    [apply, project],
  );

  const add = useCallback(async () => {
    const text = captureText(draft);
    if (text === null) return;
    if (await run({ type: "add", text })) setDraft("");
  }, [draft, run]);

  const send = useCallback(
    (item: CaptureItem) => {
      if (onSend(item.text)) {
        onClose();
        return;
      }
      toastManager.add({
        type: "error",
        title: "Unable to add to chat",
        description: "The composer is busy; try again once it is ready.",
      });
    },
    [onClose, onSend],
  );

  const copy = useCallback(async (item: CaptureItem) => {
    try {
      await writeTextToClipboard(item.text, "capture");
    } catch (cause) {
      toastManager.add({
        type: "error",
        title: "Unable to copy",
        description: cause instanceof Error ? cause.message : "The clipboard refused the text.",
      });
    }
  }, []);

  useEffect(() => {
    if (focusInputKey > 0) inputRef.current?.focus();
  }, [focusInputKey]);

  useEffect(() => {
    if (typeof document === "undefined") return;
    const closeOnOutsidePointer = (event: PointerEvent) => {
      const drawer = drawerRef.current;
      if (
        (drawer && event.composedPath().includes(drawer)) ||
        (event.target instanceof Element && event.target.closest('[data-captures-badge="true"]'))
      ) {
        return;
      }
      onClose();
    };
    document.addEventListener("pointerdown", closeOnOutsidePointer, true);
    return () => document.removeEventListener("pointerdown", closeOnOutsidePointer, true);
  }, [onClose]);

  useEffect(() => {
    if (typeof window === "undefined") return;
    const handler = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      event.preventDefault();
      event.stopPropagation();
      onClose();
    };
    window.addEventListener("keydown", handler, true);
    return () => window.removeEventListener("keydown", handler, true);
  }, [onClose]);

  return (
    <ComposerBanner.Root ref={drawerRef} data-composer-captures-drawer="true">
      <ComposerBanner.Row
        render={<button type="button" />}
        aria-label="Close captures"
        aria-expanded="true"
        onPointerDown={(event) => event.preventDefault()}
        onClick={onClose}
      >
        <ComposerBanner.Icon>
          <ListTodoIcon />
        </ComposerBanner.Icon>
        <ComposerBanner.Content className="text-muted-foreground">Captures</ComposerBanner.Content>
        <ComposerBanner.Actions>
          <ComposerBanner.Count>{rows.length}</ComposerBanner.Count>
          <ComposerBanner.ToggleIcon expanded />
        </ComposerBanner.Actions>
      </ComposerBanner.Row>
      <ComposerBanner.Body>
        {project === null ? (
          <p className="px-1 py-1 text-muted-foreground">
            Pick a project for this thread first; captures belong to a project.
          </p>
        ) : (
          <textarea
            ref={inputRef}
            rows={1}
            value={draft}
            placeholder="Type or paste, Enter to capture"
            aria-label="New capture"
            className="w-full resize-none rounded-md border border-border/60 bg-background px-2 py-1 text-[13px] text-foreground outline-none placeholder:text-muted-foreground focus-visible:ring-2 focus-visible:ring-ring"
            onChange={(event) => setDraft(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter" && !event.shiftKey) {
                event.preventDefault();
                event.stopPropagation();
                void add();
              }
            }}
          />
        )}
      </ComposerBanner.Body>
      <ComposerBanner.Scroll>
        <ComposerBanner.Children render={<ul role="list" />} aria-label="Captures">
          {project !== null && rows.length === 0 ? (
            <ComposerBanner.Row render={<li />}>
              <ComposerBanner.Icon />
              <ComposerBanner.Content className="text-muted-foreground">
                Nothing captured yet. Select text anywhere in the app and press the capture
                shortcut, or type above.
              </ComposerBanner.Content>
            </ComposerBanner.Row>
          ) : (
            rows.map((item) => {
              const done = item.doneAt !== null;
              return (
                <ComposerBanner.Row
                  render={<li />}
                  key={item.id}
                  data-capture-item={item.id}
                  className="relative rounded-sm"
                >
                  <ComposerBanner.Icon>
                    <button
                      type="button"
                      role="checkbox"
                      aria-checked={done}
                      aria-label={done ? "Reopen capture" : "Mark capture done"}
                      className={cn(
                        "flex size-4 items-center justify-center rounded-[.25rem] border border-input",
                        done && "bg-primary text-primary-foreground",
                      )}
                      onPointerDown={(event) => event.preventDefault()}
                      onClick={() => void run({ type: "setDone", id: item.id, done: !done })}
                    >
                      {done ? <CheckIcon className="size-3" /> : null}
                    </button>
                  </ComposerBanner.Icon>
                  <ComposerBanner.Content>
                    <span
                      className={cn(
                        "min-w-0 flex-1 truncate",
                        done ? "text-muted-foreground line-through" : "text-foreground/80",
                      )}
                    >
                      {captureSnippet(item.text)}
                    </span>
                  </ComposerBanner.Content>
                  <ComposerBanner.Actions>
                    <button
                      type="button"
                      aria-label="Send to composer"
                      className="text-muted-foreground hover:text-foreground"
                      onPointerDown={(event) => event.preventDefault()}
                      onClick={() => send(item)}
                    >
                      <SendIcon className="size-3.5" />
                    </button>
                    <button
                      type="button"
                      aria-label="Copy capture"
                      className="text-muted-foreground hover:text-foreground"
                      onPointerDown={(event) => event.preventDefault()}
                      onClick={() => void copy(item)}
                    >
                      <CopyIcon className="size-3.5" />
                    </button>
                    <button
                      type="button"
                      aria-label="Remove capture"
                      className="text-muted-foreground hover:text-foreground"
                      onPointerDown={(event) => event.preventDefault()}
                      onClick={() => void run({ type: "remove", id: item.id })}
                    >
                      <XIcon className="size-3.5" />
                    </button>
                  </ComposerBanner.Actions>
                </ComposerBanner.Row>
              );
            })
          )}
        </ComposerBanner.Children>
      </ComposerBanner.Scroll>
      {doneCount > 0 ? (
        <ComposerBanner.Row
          render={<button type="button" />}
          aria-label={`Clear ${doneCount} done capture${doneCount === 1 ? "" : "s"}`}
          className="text-muted-foreground hover:text-foreground"
          onPointerDown={(event) => event.preventDefault()}
          onClick={() => void run({ type: "clearDone" })}
        >
          <ComposerBanner.Icon />
          <ComposerBanner.Content>Clear done ({doneCount})</ComposerBanner.Content>
        </ComposerBanner.Row>
      ) : null}
    </ComposerBanner.Root>
  );
});
