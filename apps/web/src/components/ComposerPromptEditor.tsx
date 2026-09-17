<<<<<<< HEAD
import { ContextChipPopover } from "./contextChipParts";
import { Button } from "./ui/button";
import { LexicalComposer, type InitialConfigType } from "@lexical/react/LexicalComposer";
import { useLexicalComposerContext } from "@lexical/react/LexicalComposerContext";
import { ContentEditable } from "@lexical/react/LexicalContentEditable";
import { LexicalErrorBoundary } from "@lexical/react/LexicalErrorBoundary";
import { HistoryPlugin } from "@lexical/react/LexicalHistoryPlugin";
import { OnChangePlugin } from "@lexical/react/LexicalOnChangePlugin";
import { PlainTextPlugin } from "@lexical/react/LexicalPlainTextPlugin";
import {
  type ComposerContextClipboardFragment,
  type ServerProviderSkill,
} from "@infinitus/contracts";
import {
  COMPOSER_CONTEXT_CLIPBOARD_MIME,
  encodeComposerContextClipboardHtml,
} from "@infinitus/shared/composerContextClipboard";
import { serializeComposerFileLink } from "@infinitus/shared/composerTrigger";
import {
  $applyNodeReplacement,
  $createRangeSelectionFromDom,
  $createRangeSelection,
  $getSelection,
  $setSelection,
  $isElementNode,
  $isLineBreakNode,
  $isRangeSelection,
  $isTextNode,
  $createLineBreakNode,
  $createParagraphNode,
  $createTextNode,
  KEY_ARROW_DOWN_COMMAND,
  KEY_ARROW_LEFT_COMMAND,
  KEY_ARROW_RIGHT_COMMAND,
  KEY_ARROW_UP_COMMAND,
  KEY_DOWN_COMMAND,
  KEY_ENTER_COMMAND,
  KEY_TAB_COMMAND,
  COMMAND_PRIORITY_HIGH,
  COPY_COMMAND,
  CUT_COMMAND,
  COMMAND_PRIORITY_LOW,
  KEY_BACKSPACE_COMMAND,
  BLUR_COMMAND,
  FOCUS_COMMAND,
  $getRoot,
  $getNodeByKey,
  HISTORY_MERGE_TAG,
  HISTORY_PUSH_TAG,
  SKIP_DOM_SELECTION_TAG,
  DecoratorNode,
  type ElementNode,
  type LexicalNode,
  type SerializedLexicalNode,
  type EditorState,
  type NodeKey,
  type Spread,
} from "lexical";
import {
  createContext,
  use,
  useCallback,
  useEffect,
  useEffectEvent,
  useImperativeHandle,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";

import {
  clampCollapsedComposerCursor,
  collapseExpandedComposerCursor,
  expandCollapsedComposerCursor,
  isCollapsedCursorAdjacentToInlineToken,
} from "~/composer-logic";
import {
  selectionTouchesMentionBoundary,
  splitPromptIntoComposerSegments,
} from "~/composer-editor-mentions";
import { collectInlineContextIds } from "~/lib/composerContextReferences";
import { cn, isMacPlatform } from "~/lib/utils";
import { basenameOfPath } from "~/pierre-icons";
import {
  COMPOSER_INLINE_CHIP_DECORATOR_CLASS_NAME,
  COMPOSER_INLINE_CHIP_ICON_CLASS_NAME,
  COMPOSER_INLINE_CHIP_LABEL_CLASS_NAME,
  COMPOSER_INLINE_SKILL_CHIP_CLASS_NAME,
  SKILL_CHIP_ICON_SVG,
} from "./composerInlineChip";
import { FILE_TAG_CHIP_CLASS_NAME, FileTagChipContent } from "./chat/FileTagChip";
import { getTimelinePageScrollKey } from "./chat/pageScrollController";
import {
  $createComposerContextReferenceNode,
  ComposerContextReferenceNode,
} from "./ComposerContextReferenceNode";
import {
  ComposerContextActionsContext,
  ComposerContextRecordsContext,
  type ComposerDraftContextRecords,
} from "./composerContextPresentation";
import { formatProviderSkillDisplayName } from "@infinitus/client-runtime/providerSkills";
import { Tooltip, TooltipPopup, TooltipTrigger } from "./ui/tooltip";
import { registerComposerInlineTokenPaste } from "./composerInlineTokenPaste";
import { didComposerSelectionChangeVisibly } from "./composerSelection";
import {
  $consumeComposerCitationCommentRequest,
  $createComposerCitationNode,
  ComposerCitationCommentContext,
  ComposerCitationNode,
  type ComposerCitationCommentRequest,
  type ComposerCitationCommentTarget,
} from "./ComposerCitationNode";

const COMPOSER_EDITOR_HMR_KEY = `composer-editor-${Math.random().toString(36).slice(2)}`;
const SURROUND_SYMBOLS: [string, string][] = [
  ["(", ")"],
  ["[", "]"],
  ["{", "}"],
  ["'", "'"],
  ['"', '"'],
  ["“", "”"],
  ["`", "`"],
  ["<", ">"],
  ["«", "»"],
  ["*", "*"],
  ["_", "_"],
];
const SURROUND_SYMBOLS_MAP = new Map<string, string>(SURROUND_SYMBOLS);
const BACKTICK_SURROUND_CLOSE_SYMBOL = SURROUND_SYMBOLS_MAP.get("`") ?? null;

type SerializedComposerMentionNode = Spread<
  {
    path: string;
    source?: string;
    type: "composer-mention";
    version: 1;
  },
  SerializedLexicalNode
>;

type SerializedComposerSkillNode = Spread<
  {
    skillName: string;
    skillLabel?: string;
    skillDescription?: string;
    type: "composer-skill";
    version: 1;
  },
  SerializedLexicalNode
>;

function ComposerMentionDecorator(props: { path: string }) {
  const actions = use(ComposerContextActionsContext);
  const theme = resolvedThemeFromDocument();
  const chip = (
    <button
      type="button"
      onClick={() => actions.openMention(props.path)}
      aria-label={`Preview ${props.path}`}
      className={`${FILE_TAG_CHIP_CLASS_NAME} cursor-pointer focus-visible:outline-2`}
      contentEditable={false}
      spellCheck={false}
      data-composer-mention-chip="true"
    >
      <FileTagChipContent path={props.path} label={basenameOfPath(props.path)} theme={theme} />
    </button>
  );

  return (
    <Tooltip>
      <TooltipTrigger render={chip} />
      <TooltipPopup side="top" className="max-w-120 whitespace-normal leading-tight wrap-anywhere">
        {props.path}
      </TooltipPopup>
    </Tooltip>
  );
}

class ComposerMentionNode extends DecoratorNode<React.ReactElement> {
  __path: string;
  __source: string;

  static override getType(): string {
    return "composer-mention";
  }

  static override clone(node: ComposerMentionNode): ComposerMentionNode {
    return new ComposerMentionNode(node.__path, node.__source, node.__key);
  }

  static override importJSON(serializedNode: SerializedComposerMentionNode): ComposerMentionNode {
    return $createComposerMentionNode(serializedNode.path, serializedNode.source).updateFromJSON(
      serializedNode,
    );
  }

  constructor(path: string, source = serializeComposerFileLink(path), key?: NodeKey) {
    super(key);
    this.__path = path;
    this.__source = source;
  }

  override exportJSON(): SerializedComposerMentionNode {
    return {
      ...super.exportJSON(),
      path: this.__path,
      source: this.__source,
      type: "composer-mention",
      version: 1,
    };
  }

  override createDOM(): HTMLElement {
    const dom = document.createElement("span");
    dom.className = COMPOSER_INLINE_CHIP_DECORATOR_CLASS_NAME;
    return dom;
  }

  override updateDOM(): false {
    return false;
  }

  override getTextContent(): string {
    return this.__source;
  }

  override isInline(): true {
    return true;
  }

  override decorate(): React.ReactElement {
    return <ComposerMentionDecorator path={this.__path} />;
  }
}

function $createComposerMentionNode(path: string, source?: string): ComposerMentionNode {
  return $applyNodeReplacement(new ComposerMentionNode(path, source));
}

function resolveSkillDescription(
  skill: Pick<ServerProviderSkill, "shortDescription" | "description">,
): string | null {
  const shortDescription = skill.shortDescription?.trim();
  if (shortDescription) {
    return shortDescription;
  }
  const description = skill.description?.trim();
  return description || null;
}

type ComposerSkillMetadata = {
  label: string;
  description: string | null;
};

function skillMetadataByName(
  skills: ReadonlyArray<ServerProviderSkill>,
): ReadonlyMap<string, ComposerSkillMetadata> {
  return new Map(
    skills.map((skill) => [
      skill.name,
      {
        label: formatProviderSkillDisplayName(skill),
        description: resolveSkillDescription(skill),
      },
    ]),
  );
}

const ComposerSkillsContext = createContext<ReadonlyArray<ServerProviderSkill>>([]);

function ComposerSkillDecorator(props: {
  skillName: string;
  skillLabel: string;
  skillDescription: string | null;
}) {
  const actions = use(ComposerContextActionsContext);
  const skill = use(ComposerSkillsContext).find((candidate) => candidate.name === props.skillName);
  return (
    <ContextChipPopover
      accessibleLabel={`Skill ${props.skillLabel}`}
      triggerClassName={COMPOSER_INLINE_SKILL_CHIP_CLASS_NAME}
      chip={
        <>
          <span
            aria-hidden="true"
            className={COMPOSER_INLINE_CHIP_ICON_CLASS_NAME}
            dangerouslySetInnerHTML={{ __html: SKILL_CHIP_ICON_SVG }}
          />
          <span className={COMPOSER_INLINE_CHIP_LABEL_CLASS_NAME}>{props.skillLabel}</span>
        </>
      }
    >
      <div className="space-y-3 p-2 text-sm">
        <p className="font-medium">{props.skillLabel}</p>
        <p>
          {skill?.description ??
            props.skillDescription ??
            "No description is available for this skill."}
        </p>
        {skill?.path ? (
          <Button variant="outline" size="sm" onClick={() => actions.openMention(skill.path)}>
            View instructions
          </Button>
        ) : null}
      </div>
    </ContextChipPopover>
  );
}

class ComposerSkillNode extends DecoratorNode<React.ReactElement> {
  __skillName: string;
  __skillLabel: string;
  __skillDescription: string | null;

  static override getType(): string {
    return "composer-skill";
  }

  static override clone(node: ComposerSkillNode): ComposerSkillNode {
    return new ComposerSkillNode(
      node.__skillName,
      node.__skillLabel,
      node.__skillDescription,
      node.__key,
    );
  }

  static override importJSON(serializedNode: SerializedComposerSkillNode): ComposerSkillNode {
    return $createComposerSkillNode(
      serializedNode.skillName,
      serializedNode.skillLabel ?? serializedNode.skillName,
      serializedNode.skillDescription ?? null,
    ).updateFromJSON(serializedNode);
  }

  constructor(
    skillName: string,
    skillLabel: string,
    skillDescription: string | null,
    key?: NodeKey,
  ) {
    super(key);
    const normalizedSkillName = skillName.startsWith("$") ? skillName.slice(1) : skillName;
    this.__skillName = normalizedSkillName;
    this.__skillLabel = skillLabel;
    this.__skillDescription = skillDescription;
  }

  override exportJSON(): SerializedComposerSkillNode {
    return {
      ...super.exportJSON(),
      skillName: this.__skillName,
      skillLabel: this.__skillLabel,
      ...(this.__skillDescription ? { skillDescription: this.__skillDescription } : {}),
      type: "composer-skill",
      version: 1,
    };
  }

  override createDOM(): HTMLElement {
    const dom = document.createElement("span");
    dom.className = COMPOSER_INLINE_CHIP_DECORATOR_CLASS_NAME;
    return dom;
  }

  override updateDOM(): false {
    return false;
  }

  override getTextContent(): string {
    return `$${this.__skillName}`;
  }

  override isInline(): true {
    return true;
  }

  override decorate(): React.ReactElement {
    return (
      <ComposerSkillDecorator
        skillName={this.__skillName}
        skillLabel={this.__skillLabel}
        skillDescription={this.__skillDescription}
      />
    );
  }
}

function $createComposerSkillNode(
  skillName: string,
  skillLabel: string,
  skillDescription: string | null,
): ComposerSkillNode {
  return $applyNodeReplacement(new ComposerSkillNode(skillName, skillLabel, skillDescription));
}

type ComposerInlineTokenNode =
  | ComposerMentionNode
  | ComposerSkillNode
  | ComposerCitationNode
  | ComposerContextReferenceNode;

function isComposerInlineTokenNode(candidate: unknown): candidate is ComposerInlineTokenNode {
  return (
    candidate instanceof ComposerMentionNode ||
    candidate instanceof ComposerSkillNode ||
    candidate instanceof ComposerCitationNode ||
    candidate instanceof ComposerContextReferenceNode
  );
}

function resolvedThemeFromDocument(): "light" | "dark" {
  return document.documentElement.classList.contains("dark") ? "dark" : "light";
}

function skillSignature(skills: ReadonlyArray<ServerProviderSkill>): string {
  return skills
    .map((skill) =>
      [
        skill.name,
        skill.displayName ?? "",
        skill.shortDescription ?? "",
        skill.description ?? "",
        skill.path,
        skill.scope ?? "",
        skill.enabled ? "1" : "0",
      ].join("\u001f"),
    )
    .join("\u001e");
}

function clampExpandedCursor(value: string, cursor: number): number {
  if (!Number.isFinite(cursor)) return value.length;
  return Math.max(0, Math.min(value.length, Math.floor(cursor)));
}

function getComposerInlineTokenTextLength(_node: ComposerInlineTokenNode): 1 {
  return 1;
}

function getComposerInlineTokenExpandedTextLength(node: ComposerInlineTokenNode): number {
  return node.getTextContentSize();
}

function getAbsoluteOffsetForInlineTokenPoint(
  node: ComposerInlineTokenNode,
  absoluteOffset: number,
  pointOffset: number,
): number {
  return absoluteOffset + (pointOffset > 0 ? getComposerInlineTokenTextLength(node) : 0);
}

function getExpandedAbsoluteOffsetForInlineTokenPoint(
  node: ComposerInlineTokenNode,
  absoluteOffset: number,
  pointOffset: number,
): number {
  return absoluteOffset + (pointOffset > 0 ? getComposerInlineTokenExpandedTextLength(node) : 0);
}

function findSelectionPointForInlineToken(
  node: ComposerInlineTokenNode,
  remainingRef: { value: number },
): { key: string; offset: number; type: "element" } | null {
  const parent = node.getParent();
  if (!parent || !$isElementNode(parent)) return null;
  const index = node.getIndexWithinParent();
  if (remainingRef.value === 0) {
    return {
      key: parent.getKey(),
      offset: index,
      type: "element",
    };
  }
  if (remainingRef.value === getComposerInlineTokenTextLength(node)) {
    return {
      key: parent.getKey(),
      offset: index + 1,
      type: "element",
    };
  }
  remainingRef.value -= getComposerInlineTokenTextLength(node);
  return null;
}

function getComposerNodeTextLength(node: LexicalNode): number {
  if (isComposerInlineTokenNode(node)) {
    return getComposerInlineTokenTextLength(node);
  }
  if ($isTextNode(node)) {
    return node.getTextContentSize();
  }
  if ($isLineBreakNode(node)) {
    return 1;
  }
  if ($isElementNode(node)) {
    return node.getChildren().reduce((total, child) => total + getComposerNodeTextLength(child), 0);
  }
  return 0;
}

function getComposerNodeExpandedTextLength(node: LexicalNode): number {
  if (isComposerInlineTokenNode(node)) {
    return getComposerInlineTokenExpandedTextLength(node);
  }
  if ($isTextNode(node)) {
    return node.getTextContentSize();
  }
  if ($isLineBreakNode(node)) {
    return 1;
  }
  if ($isElementNode(node)) {
    return node
      .getChildren()
      .reduce((total, child) => total + getComposerNodeExpandedTextLength(child), 0);
  }
  return 0;
}

function getAbsoluteOffsetForPoint(node: LexicalNode, pointOffset: number): number {
  let offset = 0;
  let current: LexicalNode | null = node;

  while (current) {
    const nextParent = current.getParent() as LexicalNode | null;
    if (!nextParent || !$isElementNode(nextParent)) {
      break;
    }
    const siblings = nextParent.getChildren();
    const index = current.getIndexWithinParent();
    for (let i = 0; i < index; i += 1) {
      const sibling = siblings[i];
      if (!sibling) continue;
      offset += getComposerNodeTextLength(sibling);
    }
    current = nextParent;
  }

  if ($isTextNode(node)) {
    return offset + Math.min(pointOffset, node.getTextContentSize());
  }
  if (isComposerInlineTokenNode(node)) {
    return getAbsoluteOffsetForInlineTokenPoint(node, offset, pointOffset);
  }

  if ($isLineBreakNode(node)) {
    return offset + Math.min(pointOffset, 1);
  }

  if ($isElementNode(node)) {
    const children = node.getChildren();
    const clampedOffset = Math.max(0, Math.min(pointOffset, children.length));
    for (let i = 0; i < clampedOffset; i += 1) {
      const child = children[i];
      if (!child) continue;
      offset += getComposerNodeTextLength(child);
    }
    return offset;
  }

  return offset;
}

function getExpandedAbsoluteOffsetForPoint(node: LexicalNode, pointOffset: number): number {
  let offset = 0;
  let current: LexicalNode | null = node;

  while (current) {
    const nextParent = current.getParent() as LexicalNode | null;
    if (!nextParent || !$isElementNode(nextParent)) {
      break;
    }
    const siblings = nextParent.getChildren();
    const index = current.getIndexWithinParent();
    for (let i = 0; i < index; i += 1) {
      const sibling = siblings[i];
      if (!sibling) continue;
      offset += getComposerNodeExpandedTextLength(sibling);
    }
    current = nextParent;
  }

  if ($isTextNode(node)) {
    return offset + Math.min(pointOffset, node.getTextContentSize());
  }
  if (isComposerInlineTokenNode(node)) {
    return getExpandedAbsoluteOffsetForInlineTokenPoint(node, offset, pointOffset);
  }

  if ($isLineBreakNode(node)) {
    return offset + Math.min(pointOffset, 1);
  }

  if ($isElementNode(node)) {
    const children = node.getChildren();
    const clampedOffset = Math.max(0, Math.min(pointOffset, children.length));
    for (let i = 0; i < clampedOffset; i += 1) {
      const child = children[i];
      if (!child) continue;
      offset += getComposerNodeExpandedTextLength(child);
    }
    return offset;
  }

  return offset;
}

function findSelectionPointAtOffset(
  node: LexicalNode,
  remainingRef: { value: number },
): { key: string; offset: number; type: "text" | "element" } | null {
  if (isComposerInlineTokenNode(node)) {
    return findSelectionPointForInlineToken(node, remainingRef);
  }

  if ($isTextNode(node)) {
    const size = node.getTextContentSize();
    if (remainingRef.value <= size) {
      return {
        key: node.getKey(),
        offset: remainingRef.value,
        type: "text",
      };
    }
    remainingRef.value -= size;
    return null;
  }

  if ($isLineBreakNode(node)) {
    const parent = node.getParent();
    if (!parent) return null;
    const index = node.getIndexWithinParent();
    if (remainingRef.value === 0) {
      return {
        key: parent.getKey(),
        offset: index,
        type: "element",
      };
    }
    if (remainingRef.value === 1) {
      return {
        key: parent.getKey(),
        offset: index + 1,
        type: "element",
      };
    }
    remainingRef.value -= 1;
    return null;
  }

  if ($isElementNode(node)) {
    const children = node.getChildren();
    for (const child of children) {
      const point = findSelectionPointAtOffset(child, remainingRef);
      if (point) {
        return point;
      }
    }
    if (remainingRef.value === 0) {
      return {
        key: node.getKey(),
        offset: children.length,
        type: "element",
      };
    }
  }

  return null;
}

function $getComposerRootLength(): number {
  const root = $getRoot();
  const children = root.getChildren();
  return children.reduce((sum, child) => sum + getComposerNodeTextLength(child), 0);
}

function $setSelectionAtComposerOffset(nextOffset: number): void {
  const root = $getRoot();
  const composerLength = $getComposerRootLength();
  const boundedOffset = Math.max(0, Math.min(nextOffset, composerLength));
  const remainingRef = { value: boundedOffset };
  const point = findSelectionPointAtOffset(root, remainingRef) ?? {
    key: root.getKey(),
    offset: root.getChildren().length,
    type: "element" as const,
  };
  const selection = $createRangeSelection();
  selection.anchor.set(point.key, point.offset, point.type);
  selection.focus.set(point.key, point.offset, point.type);
  $setSelection(selection);
}

function $setSelectionRangeAtComposerOffsets(startOffset: number, endOffset: number): void {
  const root = $getRoot();
  const composerLength = $getComposerRootLength();
  const boundedStart = Math.max(0, Math.min(startOffset, composerLength));
  const boundedEnd = Math.max(0, Math.min(endOffset, composerLength));
  const anchorRemainingRef = { value: boundedStart };
  const focusRemainingRef = { value: boundedEnd };
  const anchorPoint = findSelectionPointAtOffset(root, anchorRemainingRef) ?? {
    key: root.getKey(),
    offset: root.getChildren().length,
    type: "element" as const,
  };
  const focusPoint = findSelectionPointAtOffset(root, focusRemainingRef) ?? {
    key: root.getKey(),
    offset: root.getChildren().length,
    type: "element" as const,
  };
  const selection = $createRangeSelection();
  selection.anchor.set(anchorPoint.key, anchorPoint.offset, anchorPoint.type);
  selection.focus.set(focusPoint.key, focusPoint.offset, focusPoint.type);
  $setSelection(selection);
}

function getSelectionRangeForExpandedComposerOffsets(selection: ReturnType<typeof $getSelection>): {
  start: number;
  end: number;
} | null {
  if (!$isRangeSelection(selection)) {
    return null;
  }
  const anchorNode = selection.anchor.getNode();
  const focusNode = selection.focus.getNode();
  const anchorOffset = getExpandedAbsoluteOffsetForPoint(anchorNode, selection.anchor.offset);
  const focusOffset = getExpandedAbsoluteOffsetForPoint(focusNode, selection.focus.offset);
  return {
    start: Math.min(anchorOffset, focusOffset),
    end: Math.max(anchorOffset, focusOffset),
  };
}

function $selectionTouchesInlineToken(selection: ReturnType<typeof $getSelection>): boolean {
  if (!$isRangeSelection(selection)) {
    return false;
  }
  return selection.getNodes().some((node) => isComposerInlineTokenNode(node));
}

function $readSelectionOffsetFromEditorState(fallback: number): number {
  const selection = $getSelection();
  if (!$isRangeSelection(selection) || !selection.isCollapsed()) {
    return fallback;
  }
  const anchorNode = selection.anchor.getNode();
  const offset = getAbsoluteOffsetForPoint(anchorNode, selection.anchor.offset);
  const composerLength = $getComposerRootLength();
  return Math.max(0, Math.min(offset, composerLength));
}

function $readExpandedSelectionOffsetFromEditorState(fallback: number): number {
  const selection = $getSelection();
  if (!$isRangeSelection(selection) || !selection.isCollapsed()) {
    return fallback;
  }
  const anchorNode = selection.anchor.getNode();
  const offset = getExpandedAbsoluteOffsetForPoint(anchorNode, selection.anchor.offset);
  const expandedLength = $getRoot().getTextContent().length;
  return Math.max(0, Math.min(offset, expandedLength));
}

function $appendTextWithLineBreaks(parent: ElementNode, text: string): void {
  const lines = text.split("\n");
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index] ?? "";
    if (line.length > 0) {
      parent.append($createTextNode(line));
    }
    if (index < lines.length - 1) {
      parent.append($createLineBreakNode());
    }
  }
}

function $setComposerEditorPrompt(
  prompt: string,
  skillMetadata: ReadonlyMap<string, ComposerSkillMetadata>,
): void {
  const root = $getRoot();
  root.clear();
  const paragraph = $createParagraphNode();
  root.append(paragraph);

  const segments = splitPromptIntoComposerSegments(prompt);
  for (const segment of segments) {
    if (segment.type === "citation") {
      paragraph.append($createComposerCitationNode(segment.citation, segment.source));
      continue;
    }
    if (segment.type === "mention") {
      paragraph.append($createComposerMentionNode(segment.path, segment.source));
      continue;
    }
    if (segment.type === "skill") {
      const metadata = skillMetadata.get(segment.name);
      paragraph.append(
        $createComposerSkillNode(
          segment.name,
          metadata?.label ?? formatProviderSkillDisplayName({ name: segment.name }),
          metadata?.description ?? null,
        ),
      );
      continue;
    }
    if (segment.type === "context-reference") {
      paragraph.append(
        $createComposerContextReferenceNode({
          kind: segment.kind,
          contextId: segment.contextId,
          label: segment.label,
        }),
      );
      continue;
    }
    $appendTextWithLineBreaks(paragraph, segment.text);
  }
}

function collectContextIdOccurrences(node: LexicalNode): string[] {
  if (node instanceof ComposerContextReferenceNode) {
    return [node.__contextId];
  }
  if ($isElementNode(node)) {
    return node.getChildren().flatMap((child) => collectContextIdOccurrences(child));
  }
  return [];
}

/** Payload ids referenced by the document, once each in first-occurrence order. */
function collectContextIds(node: LexicalNode): string[] {
  return Array.from(new Set(collectContextIdOccurrences(node)));
}

export interface ComposerPromptEditorHandle {
  focus: () => void;
  focusAt: (cursor: number) => void;
  focusAtEnd: () => void;
  readSelectionRange: () => { start: number; end: number };
  requestCitationComment: (request: ComposerCitationCommentRequest) => void;
  readSnapshot: () => {
    value: string;
    cursor: number;
    expandedCursor: number;
    contextIds: string[];
  };
  /**
   * True when a collapsed caret sits on the first ("start") or last ("end")
   * visual line, counting soft wraps. Prompt history only claims ArrowUp and
   * ArrowDown at these edges so arrows still move the caret inside multiline
   * text.
   */
  isCaretOnVisualEdge: (edge: "start" | "end") => boolean;
}

interface ComposerPromptEditorProps {
  value: string;
  cursor: number;
  /** Draft records behind the prompt's context references, keyed by context id. */
  contextRecords: ComposerDraftContextRecords;
  /** Structured clipboard payload for the given referenced ids, or null to skip. */
  buildContextClipboardFragment?:
    | ((contextIds: ReadonlyArray<string>) => string | null)
    | undefined;
  /** Imports a structured paste's records; returns ids that changed. */
  importContextFragment?:
    | ((fragment: ComposerContextClipboardFragment) => ReadonlyMap<string, string>)
    | undefined;
  skills: ReadonlyArray<ServerProviderSkill>;
  disabled: boolean;
  placeholder: string;
  containerClassName?: string;
  className?: string;
  placeholderClassName?: string;
  onChange: (
    nextValue: string,
    nextCursor: number,
    expandedCursor: number,
    cursorAdjacentToMention: boolean,
    contextIds: string[],
  ) => void;
  onVisibleSelectionChange?: () => void;
  onCommandKeyDown?: (
    key: "ArrowDown" | "ArrowUp" | "Enter" | "Tab",
    event: KeyboardEvent,
  ) => boolean;
  onPageScrollKeyDown?: (key: "PageUp" | "PageDown") => void;
  onPageScrollKeyUp?: (key: string) => void;
  onPageScrollRelease?: () => void;
  onCitationSubmitAndSend?: () => void;
  onPaste: React.ClipboardEventHandler<HTMLElement>;
  editorRef: React.RefObject<ComposerPromptEditorHandle | null>;
}
=======
import { ComposerPromptEditorTiptap } from "./ComposerPromptEditorTiptap";
import type { ComposerPromptEditorProps } from "./ComposerPromptEditorTiptap";

export type {
  ComposerCitationCommentRequest,
  ComposerPromptEditorHandle,
  ComposerPromptEditorProps,
} from "./ComposerPromptEditorTiptap";
>>>>>>> upstream-sync-d4d5d12e8-upstream-renamed

/**
 * The composer editor. Tiptap in both modes: the `richTextEnabled` setting
 * toggles Markdown styling, never the engine. Plain mode renders every
 * marker as a literal character and serializes byte-identically.
 */
export function ComposerPromptEditor(props: ComposerPromptEditorProps) {
  return <ComposerPromptEditorTiptap {...props} />;
}
