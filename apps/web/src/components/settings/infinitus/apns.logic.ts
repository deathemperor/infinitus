import type { InfinitusManifestCommand, InfinitusPrefs } from "@t3tools/contracts/infinitus";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";

/**
 * Settings › Infinitus › Devices, the phone-alert push setup (#1178): the Mac
 * pushes its own notifications to the phone with an APNs key from the user's
 * developer account. The key ids are ordinary prefs (`apns_team_id`,
 * `apns_key_id`, drawn by the prefs panel); this module backs the card below
 * them — the `apns` read (`{keyPresent, teamId, keyId, registrations}`, never
 * a token) and the `.p8` upload over `infinitus.secret` as `apns-key`. Pure:
 * the key's text never enters this module beyond the header check.
 */

const APNS_READ_VERB = "apns";
const APNS_KEY_VERB = "apns-key";

/** A build whose manifest lists the read verb and marks `apns-key` as taking
    its secret on stdin (native #1218); the server refuses `infinitus.secret`
    for a verb without that marker, so the name alone is not enough. */
export function apnsSupported(commands: ReadonlyArray<InfinitusManifestCommand>): boolean {
  const byName = new Map(commands.map((command) => [command.name, command]));
  return byName.has(APNS_READ_VERB) && byName.get(APNS_KEY_VERB)?.stdin === "secret";
}

const ApnsRegistration = Schema.Struct({
  deviceId: Schema.String,
  deviceName: Schema.String,
  kind: Schema.String,
  environment: Schema.String,
  registeredAt: Schema.String,
});
export type ApnsRegistration = typeof ApnsRegistration.Type;

/** Each row decodes on its own, so a row a newer app words differently is
    dropped alone rather than blanking the list. */
const ApnsReply = Schema.Struct({
  keyPresent: Schema.Boolean,
  teamId: Schema.String,
  keyId: Schema.String,
  registrations: Schema.Array(Schema.Unknown),
});

const decodeReply = Schema.decodeUnknownOption(ApnsReply);
const decodeRegistration = Schema.decodeUnknownOption(ApnsRegistration);

export interface ApnsStatus {
  readonly keyPresent: boolean;
  readonly teamId: string;
  readonly keyId: string;
  readonly registrations: ReadonlyArray<ApnsRegistration>;
}

/** The `apns` reply, null when the shape is not the one above. */
export function parseApnsStatus(result: unknown): ApnsStatus | null {
  const reply = Option.getOrNull(decodeReply(result));
  if (reply === null) return null;
  return {
    keyPresent: reply.keyPresent,
    teamId: reply.teamId,
    keyId: reply.keyId,
    registrations: reply.registrations.flatMap((row) =>
      Option.match(decodeRegistration(row), { onNone: () => [], onSome: (parsed) => [parsed] }),
    ),
  };
}

const PEM_PRIVATE_KEY_HEADER = "-----BEGIN PRIVATE KEY-----";

/** The check the Mac itself makes on the key: a `.p8` is a PEM private key.
    Made here too so a misclicked file is never sent — the whole file would
    otherwise travel as the secret. */
export function isPemPrivateKey(text: string): boolean {
  return text.trimStart().startsWith(PEM_PRIVATE_KEY_HEADER);
}

/** The `apns_key_id` pref's value off the snapshot, blank when unset or
    absent: the Mac stores the key under it and refuses `apns-key` until it
    is set, and the snapshot is refreshed after every write, so the card's
    gate follows the pref row above it. */
export function apnsKeyIdFromPrefs(prefs: InfinitusPrefs | undefined): string {
  const value = prefs?.prefs.find((pref) => pref.key === "apns_key_id")?.value;
  return typeof value === "string" ? value : "";
}

/** One list row: the phone, the push kind it registered for, the APNs
    environment its build uses. */
export function registrationLine(row: ApnsRegistration): string {
  return `${row.deviceName} · ${row.kind} · ${row.environment}`;
}
