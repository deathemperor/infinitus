/**
 * What leaves the machine for a team is redacted first (#1592; the port of
 * the Mac's `TeamRedaction.swift`, rule for rule). One regex pass per JSONL
 * line; every replacement is plain ASCII without quotes or backslashes, so a
 * JSON line stays JSON. The rules fail safe, not exact: prose containing a
 * literal `Authorization:` or a path under `/Users/x` can over-redact, and
 * leaking a secret is worse than mangling a sentence.
 */
export interface TeamRedactionOptions {
  /** The member's home directory, normalised to `~`. */
  readonly home: string;
  /** Pasted images ride as base64 blocks; dropped unless asked for. */
  readonly includeImages?: boolean;
}

/**
 * A transcript line is JSON, so a multi-line tool result is one physical
 * line where real newlines and tabs are the two-character escapes `\n`,
 * `\t`, `\r`: a secret can sit right after one of those instead of after
 * a word-boundary character. `B` is a leading boundary that accepts
 * either, captured as `$1` and replayed at the front of the replacement so
 * the escape survives.
 */
const B = String.raw`(^|[^A-Za-z0-9_]|\\[nrt])`;

/** Order matters: the `Authorization:` header rule eats "Bearer …" before
    the bare bearer rule sees it. */
const rules: ReadonlyArray<readonly [RegExp, string]> = [
  [
    new RegExp(String.raw`authorization:\s*[^\s"'\\]+(?:\s+[^\s"'\\]+)?`, "gi"),
    "Authorization: [redacted]",
  ],
  [new RegExp(B + String.raw`bearer\s+[A-Za-z0-9._~+/=-]{16,}`, "gi"), "$1Bearer [redacted]"],
  [new RegExp(B + String.raw`sk-[A-Za-z0-9_-]{16,}`, "g"), "$1[redacted-key]"],
  [
    new RegExp(B + String.raw`(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})`, "g"),
    "$1[redacted-key]",
  ],
  [new RegExp(B + String.raw`(?:AKIA|ASIA)[A-Z0-9]{16}\b`, "g"), "$1[redacted-aws-key]"],
  [
    new RegExp(
      String.raw`(aws_secret_access_key|aws_session_token|secretaccesskey|sessiontoken)(\\?"?\s*[=:]\s*\\?"?)[A-Za-z0-9+/=]{16,}`,
      "gi",
    ),
    "$1$2[redacted]",
  ],
  [
    new RegExp(
      String.raw`https://(?:hooks\.slack\.com|discord(?:app)?\.com/api/webhooks|outlook\.office\.com/webhook)/[^\s"'\\]+`,
      "g",
    ),
    "[redacted-webhook]",
  ],
  [
    new RegExp(
      B + String.raw`([A-Z][A-Z0-9_]*(?:KEY|SECRET|TOKEN|PASSWORD|PASSWD))=([^\s"'\\]+)`,
      "g",
    ),
    "$1$2=[redacted]",
  ],
  // Any user's home, this machine's included: /Users/<x>, /home/<x>, /root.
  // Zero-width lookbehind, nothing to replay.
  [
    new RegExp(
      String.raw`(?<=^|[^A-Za-z0-9~]|\\[nrt])(?:/(?:Users|home)/[^/\s"'\\]+|/root(?=/|["'\s\\]|$))`,
      "g",
    ),
    "~",
  ],
];

const image = new RegExp(String.raw`"data"\s*:\s*"[A-Za-z0-9+/=]{256,}"`, "g");

const escapeRegExp = (text: string) => text.replace(/[.*+?^${}()|[\]\\]/g, String.raw`\$&`);

const homeRule = (home: string) =>
  home.length > 1 ? new RegExp(escapeRegExp(home) + String.raw`(?=/|["'\s\\]|$)`, "g") : null;

/** The per-line redactor with the home regex compiled once: what a
    publisher calls for every line of a transcript. */
export function makeRedactor(options: TeamRedactionOptions): (line: string) => string {
  const home = homeRule(options.home);
  const includeImages = options.includeImages === true;
  return (line) => {
    let out = line;
    if (home !== null) out = out.replace(home, "~");
    for (const [re, template] of rules) out = out.replace(re, template);
    if (!includeImages) out = out.replace(image, '"data":""');
    return out;
  };
}

export function redactTranscriptLine(line: string, options: TeamRedactionOptions): string {
  return makeRedactor(options)(line);
}
