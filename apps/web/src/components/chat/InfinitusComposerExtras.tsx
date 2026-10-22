import type { ResolvedKeybindingsConfig } from "@infinitus/contracts";
import { PenLineIcon } from "lucide-react";
import { useState, type ComponentType, type ReactNode } from "react";

import { randomUUID } from "~/lib/utils";
import { captures } from "~/state/captures";
import { useEnvironmentQuery } from "~/state/query";
import type { ComposerImageAttachment } from "../../composerDraftStore";
import { ComposerCapturesBadge } from "../captures/ComposerCapturesBadge";
import { ComposerCapturesMenu } from "../captures/ComposerCapturesMenu";
import { openCaptureCount } from "../captures/captures.logic";
import { useCapturesUiStore } from "../captures/capturesUiStore";
import {
  useActiveProjectRef,
  useCapturesShortcuts,
  type ActiveProjectRef,
} from "../captures/useCaptures";
import { ComposerPromptsBadge } from "../prompts/ComposerPromptsBadge";
import { ComposerPromptsMenu } from "../prompts/ComposerPromptsMenu";
import {
  promptSnippetSlashItems,
  type PromptSnippetSlashItem,
} from "../prompts/promptSnippets.logic";
import { usePromptsUiStore } from "../prompts/promptsUiStore";
import { useProjectPromptSnippets } from "../prompts/useProjectPromptSnippets";
import { Button } from "../ui/button";
import { ImageMarkupDialog } from "./ImageMarkupDialog";
import { markedFileName } from "./imageMarkup.logic";

/**
 * The fork's composer features (#1565), owned here so `ChatComposer.tsx`
 * keeps one registration line per site: the Captures popover, badge and
 * shortcuts (#433), the Prompts popover, badge and `/` menu rows (#270 G),
 * and the draw-on-image button (#875). `useInfinitusComposerExtras` is
 * called once, unconditionally, before the composer derives its command
 * menu; the components below take its result.
 */
interface InfinitusComposerExtras {
  /** The routed project; null on a draft without one. */
  readonly project: ActiveProjectRef | null;
  readonly promptSnippets: ReturnType<typeof useProjectPromptSnippets>;
  /** The project's saved prompts matching a `/` query, appended after the commands. */
  readonly slashItems: (query: string) => PromptSnippetSlashItem[];
  readonly capturesOpen: boolean;
  readonly capturesFocusInputKey: number;
  readonly promptsOpen: boolean;
}

export function useInfinitusComposerExtras(input: {
  readonly keybindings: ResolvedKeybindingsConfig;
  readonly terminalOpen: boolean;
  readonly modelPickerOpen: boolean;
}): InfinitusComposerExtras {
  // One route read for the project-scoped features; the hook is
  // identity-stable so the composer can still bail out of no-op updates (#821).
  const project = useActiveProjectRef();
  const promptSnippets = useProjectPromptSnippets(project);
  useCapturesShortcuts({ ...input, project });
  const capturesOpen = useCapturesUiStore((store) => store.open);
  const capturesFocusInputKey = useCapturesUiStore((store) => store.focusInputKey);
  const promptsOpen = usePromptsUiStore((store) => store.open);
  const slashItems = (query: string) => promptSnippetSlashItems(promptSnippets.snippets, query);
  return { project, promptSnippets, slashItems, capturesOpen, capturesFocusInputKey, promptsOpen };
}

/** The Captures and Prompts shoulder tabs, after the stash badge in the dock. */
export function InfinitusComposerBadges(props: {
  extras: InfinitusComposerExtras;
  hidden: boolean;
}) {
  const { project, promptSnippets, capturesOpen, promptsOpen } = props.extras;
  const toggleCaptures = useCapturesUiStore((store) => store.toggle);
  const togglePrompts = usePromptsUiStore((store) => store.toggle);
  const capturesQuery = useEnvironmentQuery(
    project === null
      ? null
      : captures.list({
          environmentId: project.environmentId,
          input: { projectId: project.projectId },
        }),
  );
  if (props.hidden || project === null) return null;
  return (
    <>
      <ComposerCapturesBadge
        openCount={openCaptureCount(capturesQuery.data ?? [])}
        menuOpen={capturesOpen}
        onToggleMenu={toggleCaptures}
      />
      <ComposerPromptsBadge
        count={promptSnippets.snippets.length}
        menuOpen={promptsOpen}
        onToggleMenu={togglePrompts}
      />
    </>
  );
}

/**
 * The Captures and Prompts popovers in the composer's anchored layer, after
 * the stash menu. `hidden` is the stash menu, the trigger-driven command
 * menu or the approval state, which all take the layer first; Prompts also
 * takes it over Captures.
 */
export function InfinitusComposerMenus(props: {
  extras: InfinitusComposerExtras;
  layer: ComponentType<{ anchor: HTMLElement | null; children: ReactNode }>;
  anchor: HTMLElement | null;
  hidden: boolean;
  /** Puts the text at the end of the composer; false while the composer is busy. */
  insertText: (text: string, options: { ensureLeadingBoundary: boolean }) => boolean;
}) {
  const { project, promptSnippets, capturesOpen, capturesFocusInputKey, promptsOpen } =
    props.extras;
  const Layer = props.layer;
  const closeCaptures = useCapturesUiStore((store) => store.close);
  const closePrompts = usePromptsUiStore((store) => store.close);
  const insert = (text: string) => props.insertText(text, { ensureLeadingBoundary: true });
  return (
    <>
      {capturesOpen && !promptsOpen && !props.hidden && (
        <Layer anchor={props.anchor}>
          <ComposerCapturesMenu
            project={project}
            focusInputKey={capturesFocusInputKey}
            onSend={insert}
            onClose={closeCaptures}
          />
        </Layer>
      )}
      {promptsOpen && !props.hidden && (
        <Layer anchor={props.anchor}>
          <ComposerPromptsMenu
            snippets={promptSnippets.snippets}
            projectKey={promptSnippets.projectKey}
            onInsert={insert}
            onClose={closePrompts}
          />
        </Layer>
      )}
    </>
  );
}

/**
 * An image attachment's "Draw on" button and its dialog (#875). Saving
 * swaps the attachment for the edited PNG under a new id, so the upload
 * queue (keyed by id) uploads the copy and the original is released.
 */
export function InfinitusImageMarkup(props: {
  image: ComposerImageAttachment;
  addImage: (image: ComposerImageAttachment) => void;
  removeImage: (imageId: string) => void;
}) {
  const { image } = props;
  const [open, setOpen] = useState(false);
  const save = (blob: Blob) => {
    const file = new File([blob], markedFileName(image.name), { type: "image/png" });
    props.addImage({
      type: "image",
      id: randomUUID(),
      name: file.name,
      mimeType: file.type,
      sizeBytes: file.size,
      previewUrl: URL.createObjectURL(file),
      file,
    });
    props.removeImage(image.id);
    setOpen(false);
  };
  return (
    <>
      <span className="absolute right-7 top-1 flex opacity-0 transition-opacity pointer-coarse:opacity-100 focus-within:opacity-100 group-hover/attachment:opacity-100 group-focus-within/attachment:opacity-100">
        <Button
          variant="media-close"
          size="icon-xs"
          onClick={() => setOpen(true)}
          aria-label={`Draw on ${image.name}`}
        >
          <PenLineIcon />
        </Button>
      </span>
      {open ? (
        <ImageMarkupDialog
          open
          imageName={image.name}
          previewUrl={image.previewUrl}
          onCancel={() => setOpen(false)}
          onSave={save}
        />
      ) : null}
    </>
  );
}
