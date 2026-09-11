import { scopeThreadRef } from "@t3tools/client-runtime/environment";
import {
  isAtomCommandInterrupted,
  squashAtomCommandFailure,
} from "@t3tools/client-runtime/state/runtime";
import type { EnvironmentId, ThreadId } from "@t3tools/contracts";
import { MessageCircleQuestionMarkIcon } from "lucide-react";
import { useMemo, useState, type KeyboardEvent } from "react";

import { useComposerDraftStore, type ComposerThreadTarget } from "../composerDraftStore";
import { cn } from "../lib/utils";
import { newMessageId } from "../lib/utils";
import { useThread } from "../state/entities";
import { isSideQuestionMessage } from "./SideQuestionPanel.logic";
import { threadEnvironment } from "../state/threads";
import { useAtomCommand } from "../state/use-atom-command";
import ChatMarkdown from "./ChatMarkdown";
import { Button } from "./ui/button";
import { ScrollArea } from "./ui/scroll-area";
import { Spinner } from "./ui/spinner";
import { Textarea } from "./ui/textarea";

/**
 * Fork (#269 C): the drawer of a side question. The thread behind it is a
 * fork of the main thread at its latest completed turn (`sideOf` set, plan
 * mode), so it answers from the main thread's context without touching it,
 * even while the main turn runs. Only what was asked here is shown (the
 * imported history is told apart by `isSideQuestionMessage`). "Bring to
 * main" appends the latest answer to the main composer's draft.
 */
export function SideQuestionPanel({
  environmentId,
  threadId,
  composerDraftTarget,
}: {
  environmentId: EnvironmentId;
  threadId: ThreadId;
  composerDraftTarget: ComposerThreadTarget;
}) {
  const sideRef = useMemo(() => scopeThreadRef(environmentId, threadId), [environmentId, threadId]);
  const thread = useThread(sideRef);
  const startTurn = useAtomCommand(threadEnvironment.startTurn, { reportFailure: false });
  const [text, setText] = useState("");
  const [sending, setSending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const messages = useMemo(
    () => (thread?.messages ?? []).filter((message) => isSideQuestionMessage(threadId, message)),
    [thread?.messages, threadId],
  );
  const running = (thread?.session?.activeTurnId ?? null) !== null;
  const busy = sending || running;
  const answer = useMemo(
    () =>
      messages.findLast((message) => message.role === "assistant" && !message.streaming)?.text ??
      null,
    [messages],
  );

  const send = async () => {
    const asked = text.trim();
    if (!thread || asked.length === 0 || busy) return;
    setSending(true);
    setError(null);
    const createdAt = new Date().toISOString();
    const result = await startTurn({
      environmentId,
      input: {
        threadId,
        message: { messageId: newMessageId(), role: "user", text: asked, attachments: [] },
        modelSelection: thread.modelSelection,
        runtimeMode: thread.runtimeMode,
        interactionMode: "plan",
        createdAt,
      },
    });
    setSending(false);
    if (result._tag === "Failure") {
      if (isAtomCommandInterrupted(result)) return;
      const failure = squashAtomCommandFailure(result);
      setError(failure instanceof Error ? failure.message : "Could not ask.");
      return;
    }
    setText("");
  };

  const bringToMain = () => {
    if (answer === null) return;
    const store = useComposerDraftStore.getState();
    const current = store.getComposerDraft(composerDraftTarget)?.prompt ?? "";
    store.setPrompt(
      composerDraftTarget,
      current.trim().length > 0 ? `${current.trimEnd()}\n\n${answer}` : answer,
    );
  };

  const onKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing) {
      event.preventDefault();
      void send();
    }
  };

  if (!thread) {
    return (
      <div className="flex h-full items-center justify-center p-6">
        <Spinner className="size-4 text-muted-foreground" />
      </div>
    );
  }

  return (
    <div className="flex h-full min-h-0 flex-col" data-testid="side-question-panel">
      <ScrollArea className="min-h-0 flex-1">
        <div className="flex flex-col gap-3 p-3">
          {messages.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-6 text-center">
              <MessageCircleQuestionMarkIcon
                aria-hidden
                className="size-6 text-muted-foreground/60"
              />
              <p className="text-muted-foreground text-xs">
                Ask about the thread so far. The answer stays here; the main turn is left alone.
              </p>
            </div>
          ) : null}
          {messages.map((message) => (
            <div
              key={message.id}
              className={cn(
                "max-w-full text-sm",
                message.role === "user" && "self-end rounded-md bg-muted/60 px-3 py-2",
              )}
            >
              {message.role === "user" ? (
                <span className="whitespace-pre-wrap">{message.text}</span>
              ) : (
                <ChatMarkdown
                  text={message.text}
                  cwd={thread.worktreePath ?? undefined}
                  threadRef={sideRef}
                  isStreaming={message.streaming}
                />
              )}
            </div>
          ))}
          {running ? <Spinner className="size-3.5 text-muted-foreground" /> : null}
        </div>
      </ScrollArea>
      {error !== null ? <p className="px-3 pb-1 text-destructive text-xs">{error}</p> : null}
      <div className="flex flex-col gap-2 border-t border-border/60 p-2">
        <Textarea
          value={text}
          rows={2}
          placeholder="Ask a side question…"
          aria-label="Side question"
          disabled={busy}
          onChange={(event) => setText(event.target.value)}
          onKeyDown={onKeyDown}
        />
        <div className="flex items-center justify-between gap-2">
          <Button variant="ghost" size="xs" disabled={answer === null} onClick={bringToMain}>
            Bring to main
          </Button>
          <Button size="xs" disabled={busy || text.trim().length === 0} onClick={() => void send()}>
            Ask
          </Button>
        </div>
      </div>
    </div>
  );
}
