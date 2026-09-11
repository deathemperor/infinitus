import * as Schema from "effect/Schema";

import { ProjectId, TrimmedNonEmptyString } from "./baseSchemas.ts";

/**
 * Captures (#433): one small list per project of things the user typed,
 * pasted or selected on the way to a prompt — a note, a snippet, a todo —
 * each sendable to the composer and checkable off. Kept by the server in a
 * file under its state directory (never in the workspace), streamed whole to
 * every client of the project. No kinds, tags or attachments: "send to
 * composer" is the only thing a capture is for.
 */

export const CaptureId = TrimmedNonEmptyString.pipe(Schema.brand("CaptureId"));
export type CaptureId = typeof CaptureId.Type;

/** A capture's body. Whole-line pastes are one capture, so the cap is a
    paragraph's worth (8 KiB), not a line's. */
export const MAX_CAPTURE_TEXT_LENGTH = 8_192;
export const CaptureText = TrimmedNonEmptyString.check(Schema.isMaxLength(MAX_CAPTURE_TEXT_LENGTH));

/** Captures a project holds at once, done ones included. */
export const MAX_CAPTURES_PER_PROJECT = 200;

export const CaptureItem = Schema.Struct({
  id: CaptureId,
  text: CaptureText,
  createdAt: Schema.DateTimeUtc,
  /** When it was checked off; null while open. */
  doneAt: Schema.NullOr(Schema.DateTimeUtc),
});
export type CaptureItem = typeof CaptureItem.Type;

/** The project's whole list, in the order the items were added. */
export const CaptureList = Schema.Array(CaptureItem);
export type CaptureList = typeof CaptureList.Type;

export const CapturesSubscribeInput = Schema.Struct({
  projectId: ProjectId,
});
export type CapturesSubscribeInput = typeof CapturesSubscribeInput.Type;

/** One change to a project's list. A `setDone`, `edit` or `remove` naming an
    id that is gone is a no-op: the stream is the truth, and the client may
    be acting on a list that has since changed. */
export const CaptureCommand = Schema.Union([
  Schema.Struct({ type: Schema.Literal("add"), text: CaptureText }),
  Schema.Struct({ type: Schema.Literal("edit"), id: CaptureId, text: CaptureText }),
  Schema.Struct({ type: Schema.Literal("setDone"), id: CaptureId, done: Schema.Boolean }),
  Schema.Struct({ type: Schema.Literal("remove"), id: CaptureId }),
  Schema.Struct({ type: Schema.Literal("clearDone") }),
]);
export type CaptureCommand = typeof CaptureCommand.Type;

export const CapturesApplyInput = Schema.Struct({
  projectId: ProjectId,
  command: CaptureCommand,
});
export type CapturesApplyInput = typeof CapturesApplyInput.Type;

/** The new list comes over the subscription, so a successful apply says
    nothing more. */
export const CapturesApplyResult = Schema.Struct({});
export type CapturesApplyResult = typeof CapturesApplyResult.Type;

/** The project already holds `MAX_CAPTURES_PER_PROJECT` captures; check some
    off and clear them, or remove some, before adding. */
export class CaptureListFull extends Schema.TaggedError<CaptureListFull>()("CaptureListFull", {
  projectId: ProjectId,
  limit: Schema.Number,
}) {}

/** The list's file could not be read or written. `detail` is the failure's
    own message, never the file's contents. */
export class CaptureStoreError extends Schema.TaggedError<CaptureStoreError>()(
  "CaptureStoreError",
  { projectId: ProjectId, detail: Schema.String },
) {}
