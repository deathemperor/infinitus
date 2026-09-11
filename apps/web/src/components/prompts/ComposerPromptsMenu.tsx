import type { PromptSnippet } from "@t3tools/contracts";
import { useNavigate } from "@tanstack/react-router";
import { BookmarkIcon, SettingsIcon } from "lucide-react";
import { memo, useCallback, useEffect, useRef } from "react";

import { ComposerBanner } from "../chat/ComposerBanner";
import { toastManager } from "../ui/toast";
import { promptSnippetPreview } from "./promptSnippets.logic";

/**
 * The composer's Prompts popover (#270 G): the project's saved snippets,
 * one row each; a click puts the body at the end of the composer and closes
 * the menu. Edited under Settings › Projects, linked from the foot. Drawn in
 * the composer's anchored layer like the Captures menu.
 */
export const ComposerPromptsMenu = memo(function ComposerPromptsMenu(props: {
  snippets: readonly PromptSnippet[];
  /** The project settings page to open from the foot; null while the thread has no project. */
  projectKey: string | null;
  /** Puts the text at the end of the composer; false while the composer is busy. */
  onInsert: (text: string) => boolean;
  onClose: () => void;
}) {
  const { snippets, projectKey, onInsert, onClose } = props;
  const drawerRef = useRef<HTMLDivElement>(null);
  const navigate = useNavigate();

  const insert = useCallback(
    (snippet: PromptSnippet) => {
      if (onInsert(snippet.text)) {
        onClose();
        return;
      }
      toastManager.add({
        type: "error",
        title: "Unable to add to chat",
        description: "The composer is busy; try again once it is ready.",
      });
    },
    [onClose, onInsert],
  );

  const openSettings = useCallback(() => {
    onClose();
    void navigate({
      to: "/settings/projects",
      search: { project: projectKey ?? undefined, machine: undefined },
    });
  }, [navigate, onClose, projectKey]);

  useEffect(() => {
    if (typeof document === "undefined") return;
    const closeOnOutsidePointer = (event: PointerEvent) => {
      const drawer = drawerRef.current;
      if (
        (drawer && event.composedPath().includes(drawer)) ||
        (event.target instanceof Element && event.target.closest('[data-prompts-badge="true"]'))
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
    <ComposerBanner.Root ref={drawerRef} data-composer-prompts-drawer="true">
      <ComposerBanner.Row
        render={<button type="button" />}
        aria-label="Close prompts"
        aria-expanded="true"
        onPointerDown={(event) => event.preventDefault()}
        onClick={onClose}
      >
        <ComposerBanner.Icon>
          <BookmarkIcon />
        </ComposerBanner.Icon>
        <ComposerBanner.Content className="text-muted-foreground">Prompts</ComposerBanner.Content>
        <ComposerBanner.Actions>
          <ComposerBanner.Count>{snippets.length}</ComposerBanner.Count>
          <ComposerBanner.ToggleIcon expanded />
        </ComposerBanner.Actions>
      </ComposerBanner.Row>
      <ComposerBanner.Scroll>
        <ComposerBanner.Children render={<ul role="list" />} aria-label="Saved prompts">
          {snippets.length === 0 ? (
            <ComposerBanner.Row render={<li />}>
              <ComposerBanner.Icon />
              <ComposerBanner.Content className="text-muted-foreground">
                No saved prompts for this project yet. Add some under Settings › Projects.
              </ComposerBanner.Content>
            </ComposerBanner.Row>
          ) : (
            snippets.map((snippet) => (
              <ComposerBanner.Row
                render={<li />}
                key={snippet.id}
                data-prompt-snippet={snippet.id}
                className="relative rounded-sm"
              >
                <ComposerBanner.Icon />
                <ComposerBanner.Content>
                  <button
                    type="button"
                    aria-label={`Insert prompt ${snippet.name}`}
                    className="flex min-w-0 flex-1 items-baseline gap-2 truncate text-start hover:text-foreground"
                    onPointerDown={(event) => event.preventDefault()}
                    onClick={() => insert(snippet)}
                  >
                    <span className="truncate text-foreground/80">{snippet.name}</span>
                    <span className="min-w-0 flex-1 truncate text-muted-foreground">
                      {promptSnippetPreview(snippet.text)}
                    </span>
                  </button>
                </ComposerBanner.Content>
              </ComposerBanner.Row>
            ))
          )}
        </ComposerBanner.Children>
      </ComposerBanner.Scroll>
      <ComposerBanner.Row
        render={<button type="button" />}
        aria-label="Edit saved prompts in project settings"
        className="text-muted-foreground hover:text-foreground"
        onPointerDown={(event) => event.preventDefault()}
        onClick={openSettings}
      >
        <ComposerBanner.Icon>
          <SettingsIcon />
        </ComposerBanner.Icon>
        <ComposerBanner.Content>Edit prompts…</ComposerBanner.Content>
      </ComposerBanner.Row>
    </ComposerBanner.Root>
  );
});
