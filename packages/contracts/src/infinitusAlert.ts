import * as Schema from "effect/Schema";

import { TrimmedNonEmptyString } from "./baseSchemas.ts";

/**
 * An account alert the Mac app hands the desktop server to push to the
 * phones (#1375): `POST /api/infinitus/alert`, bearer-authenticated with
 * the desktop credential the server mints for the Mac. The server signs it
 * for the relay's alert route and answers how many phones were addressed.
 * Both fields are capped: an alert is one line, and the relay truncates
 * longer ones anyway.
 */
export const InfinitusAlertInput = Schema.Struct({
  title: TrimmedNonEmptyString.check(Schema.isMaxLength(120)),
  body: TrimmedNonEmptyString.check(Schema.isMaxLength(500)),
});
export type InfinitusAlertInput = typeof InfinitusAlertInput.Type;

export const InfinitusAlertResult = Schema.Struct({
  /** Phones the relay queued the alert for; zero when none is linked. */
  deliveries: Schema.Number,
});
export type InfinitusAlertResult = typeof InfinitusAlertResult.Type;

/** This server holds no relay link, so it cannot push: the Mac shows the
    notice locally and logs it once, no retry. */
export class InfinitusAlertRelayUnlinked extends Schema.TaggedError<InfinitusAlertRelayUnlinked>()(
  "InfinitusAlertRelayUnlinked",
  {},
  { httpApiStatus: 503 },
) {}
