import type { ResolvedKeybindingsConfig } from "@infinitus/contracts";
import { PenLineIcon } from "lucide-react";
import { useState, type ComponentType, type ReactNode } from "react";

import type { ComposerImageAttachment } from "../../composerDraftStore";
import { randomUUID } from "~/lib/utils";
import { captures as capturesAtoms } from "~/state/captures";
import { useEnvironmentQuery } from "~/state/query";
import { ComposerCapturesBadge } from "../captures/ComposerCapturesBadge";
import { ComposerCapturesMenu } from "../captures/ComposerCapturesMenu";
import { openCaptureCount } from "../captures/captures.logic";
import { useCapturesUiStore } from "../captures/capturesUiStore";
import { useActiveProjectRef, useCapturesShortcuts } from "../captures/useCaptures";
import { ComposerPromptsBadge } from "../prompts/ComposerPromptsBadge";
import { ComposerPromptsMenu } from "../prompts/ComposerPromptsMenu";
import { usePromptsUiStore } from "../prompts/promptsUiStore";
import { useProjectPromptSnippets } from "../prompts/useProjectPromptSnippets";
import { Button } from "../ui/button";
import { ImageMarkupDialog } from "./ImageMarkupDialog";
import { markedFileName } from "./imageMarkup.logic";

/**
 * The fork's project-scoped composer features, Captures (#433) and Prompts
 * (#270 G), as one hook the composer calls before it derives the `/` menu
 * (which lists the snippets too): the routed project, read once through
 * `useActiveProjectRef` (identity-stable, so the composer still bails out of
 * no-op updates, #821), each popover's open state, the badge counts, and the
 * two capture shortcuts.
 */
export function useInfinitusComposer(input: {
  readonly keybindings: ResolvedKeybindingsConfig;
  readonly terminalOpen: boolean;
  readonly modelPickerOpen: boolean;
}) {
  const project = useActiveProjectRef();
  const promptSnippets = useProjectPromptSnippets(project);
  const capturesMenuOpen = useCapturesUiStore((store) => store.open);
  const capturesFocusInputKey = useCapturesUiStore((store) => store.focusInputKey);
  const toggleCapturesMenu = useCapturesUiStore((store) => store.toggle);
  const closeCapturesMenu = useCapturesUiStore((store) => store.close);
  const capturesQuery = useEnvironmentQuery(
    project === null
      ? null
      : capturesAtoms.list({
          environmentId: project.environmentId,
          input: { projectId: project.projectId },
        }),
  );
  useCapturesShortcuts({
    keybindings: input.keybindings,
    terminalOpen: input.terminalOpen,
    modelPickerOpen: input.modelPickerOpen,
    project,
  });
  const promptsMenuOpen = usePromptsUiStore((store) => store.open);
  const togglePromptsMenu = usePromptsUiStore((store) => store.toggle);
  const closePromptsMenu = usePromptsUiStore((store) => store.close);
  return {
    project,
    promptSnippets,
    captures: {
      menuOpen: capturesMenuOpen,
      focusInputKey: capturesFocusInputKey,
      openCount: openCaptureCount(capturesQuery.data ?? []),
      toggleMenu: toggleCapturesMenu,
      closeMenu: closeCapturesMenu,
    },
    prompts: {
      menuOpen: promptsMenuOpen,
      toggleMenu: togglePromptsMenu,
      closeMenu: closePromptsMenu,
    },
  };
}

export type InfinitusComposer = ReturnType<typeof useInfinitusComposer>;

/** The Captures and Prompts badges in the composer's banner dock, after
    upstream's stash badge; nothing without a routed project. */
export function InfinitusComposerBadges({
  composer,
  hidden,
}: {
  composer: InfinitusComposer;
  /** True in the approval state, where upstream hides its own badges too. */
  hidden: boolean;
}) {
  if (hidden || composer.project === null) return null;
  return (
    <>
      <ComposerCapturesBadge
        openCount={composer.captures.openCount}
        menuOpen={composer.captures.menuOpen}
        onToggleMenu={composer.captures.toggleMenu}
      />
      <ComposerPromptsBadge
        count={composer.promptSnippets.snippets.length}
        menuOpen={composer.prompts.menuOpen}
        onToggleMenu={composer.prompts.toggleMenu}
      />
    </>
  );
}

/**
 * The Captures or Prompts popover in the composer's command-menu layer.
 * Never over upstream's own popovers (`suppressed`: the stash menu, the
 * trigger-driven command menu, the approval state), and Prompts wins when
 * both stores say open.
 */
export function InfinitusComposerMenus({
  composer,
  suppressed,
  anchor,
  layer: Layer,
  onInsert,
}: {
  composer: InfinitusComposer;
  suppressed: boolean;
  anchor: HTMLElement | null;
  /** Upstream's `ComposerCommandMenuLayer`, private to the composer file. */
  layer: ComponentType<{ anchor: HTMLElement | null; children: ReactNode }>;
  onInsert: (text: string) => void;
}) {
  if (suppressed) return null;
  if (composer.prompts.menuOpen) {
    return (
      <Layer anchor={anchor}>
        <ComposerPromptsMenu
          snippets={composer.promptSnippets.snippets}
          projectKey={composer.promptSnippets.projectKey}
          onInsert={onInsert}
          onClose={composer.prompts.closeMenu}
        />
      </Layer>
    );
  }
  if (composer.captures.menuOpen) {
    return (
      <Layer anchor={anchor}>
        <ComposerCapturesMenu
          project={composer.project}
          focusInputKey={composer.captures.focusInputKey}
          onSend={onInsert}
          onClose={composer.captures.closeMenu}
        />
      </Layer>
    );
  }
  return null;
}

/**
 * Fork (#875): the draft image being drawn on, if any. Saving swaps the
 * attachment for the edited PNG under a new id, so the upload queue (keyed
 * by id) uploads the copy and the original is released.
 */
export function useComposerImageMarkup(input: {
  readonly addImage: (image: ComposerImageAttachment) => void;
  readonly removeImage: (imageId: string) => void;
}) {
  const [imageId, setImageId] = useState<string | null>(null);
  return {
    imageId,
    open: (id: string) => setImageId(id),
    cancel: () => setImageId(null),
    save: (image: ComposerImageAttachment, blob: Blob) => {
      const file = new File([blob], markedFileName(image.name), { type: "image/png" });
      input.addImage({
        type: "image",
        id: randomUUID(),
        name: file.name,
        mimeType: file.type,
        sizeBytes: file.size,
        previewUrl: URL.createObjectURL(file),
        file,
      });
      input.removeImage(image.id);
      setImageId(null);
    },
  };
}

export type ComposerImageMarkup = ReturnType<typeof useComposerImageMarkup>;

/** The "Draw on" button in an image attachment's frame, left of upstream's
    remove button, and the markup dialog while this image is the one open. */
export function ComposerImageMarkupControl({
  image,
  markup,
}: {
  image: ComposerImageAttachment;
  markup: ComposerImageMarkup;
}) {
  return (
    <>
      <span className="absolute right-7 top-1 flex opacity-0 transition-opacity pointer-coarse:opacity-100 focus-within:opacity-100 group-hover/attachment:opacity-100 group-focus-within/attachment:opacity-100">
        <Button
          variant="media-close"
          size="icon-xs"
          onClick={() => markup.open(image.id)}
          aria-label={`Draw on ${image.name}`}
        >
          <PenLineIcon />
        </Button>
      </span>
      {markup.imageId === image.id ? (
        <ImageMarkupDialog
          open
          imageName={image.name}
          previewUrl={image.previewUrl}
          onCancel={markup.cancel}
          onSave={(blob) => markup.save(image, blob)}
        />
      ) : null}
    </>
  );
}
