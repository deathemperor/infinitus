/**
 * Finding Infinitus desktop servers on the phone's own Wi‑Fi (#651), as pure
 * pieces: which addresses to try, and what a reply has to look like. The
 * probe itself (fetch, timeouts, concurrency) lives in `lanDiscovery.ts`.
 *
 * No Bonjour: that needs a native module the Expo build does not carry. The
 * desktop server already answers `/.well-known/t3/environment` without auth
 * on every interface once Network access is on, so a sweep of the phone's
 * /24 on the fork's server port finds it in a few seconds.
 */

/** The desktop app's server port; the Devices card's `fork_server_port` default. */
export const INFINITUS_SERVER_PORT = 3773;

export const WELL_KNOWN_ENVIRONMENT_PATH = "/.well-known/t3/environment";

export interface NearbyServer {
  /** One row per server, whichever of its addresses answered first. */
  readonly environmentId: string;
  /** `ip:port`, what the Host field takes: the server's own first LAN base
      URL (#757, the address it would put on its Devices card) when it
      reports one, else the address that answered. */
  readonly host: string;
  readonly label: string;
  /** The server reports the Infinitus capability, so it is a fork build. */
  readonly infinitus: boolean;
}

const LAN_BASE_URL = /^http:\/\/((?:\d{1,3}\.){3}\d{1,3})(?::(\d{1,5}))?\/?$/;

/** The host the server itself reports for its own network, when the first
    entry is a plain `http://<ipv4>[:port]`; anything else (absent, a name,
    https) falls back to the address that answered. */
export function preferredHost(ip: string, port: number, lanHttpBaseUrls: unknown): string {
  const first = Array.isArray(lanHttpBaseUrls) ? lanHttpBaseUrls[0] : undefined;
  const match = typeof first === "string" ? LAN_BASE_URL.exec(first) : null;
  if (match === null) return `${ip}:${port}`;
  return `${match[1]}:${match[2] ?? "80"}`;
}

/** After "Use" filled the Host from a found Mac, Add waits for the one-time
    code: without it upstream's pairing refuses with "Pairing URL is
    invalid.", which says nothing about what is missing (#661 follow-up).
    Typing another host lifts the gate; approve-on-Mac has its own button. */
export function pickedHostNeedsCode(input: {
  readonly pickedHost: string | null;
  readonly hostInput: string;
  readonly codeInput: string;
}): boolean {
  return (
    input.pickedHost !== null &&
    input.hostInput.trim() === input.pickedHost &&
    input.codeInput.trim().length === 0
  );
}

export const PICKED_HOST_HINT =
  "Now type the pairing code from the Mac's Devices card, or ask the Mac to approve.";

const PRIVATE_IPV4 = /^(10\.\d+|172\.(1[6-9]|2\d|3[01])|192\.168)\.\d+\.\d+$/;

/**
 * Every other host on the phone's /24 — private IPv4 only, since a public or
 * carrier address is not a network anyone runs a Mac on. Empty when the
 * address is missing, IPv6, or not private.
 */
export function subnetCandidates(ownIp: string | null): ReadonlyArray<string> {
  if (ownIp === null || !PRIVATE_IPV4.test(ownIp)) return [];
  const octets = ownIp.split(".").map(Number);
  if (octets.some((octet) => octet > 255)) return [];
  const prefix = octets.slice(0, 3).join(".");
  const own = octets[3];
  const hosts: string[] = [];
  for (let last = 1; last <= 254; last += 1) {
    if (last !== own) hosts.push(`${prefix}.${last}`);
  }
  return hosts;
}

/** The /24 a sweep covers, "192.168.2.0/24", or null when `subnetCandidates`
    has nothing for the address. */
export function subnetLabel(ownIp: string | null): string | null {
  if (subnetCandidates(ownIp).length === 0) return null;
  return `${ownIp!.split(".").slice(0, 3).join(".")}.0/24`;
}

/**
 * What one sweep did, for the line under the button (#787): with the
 * counts a report says which suspect it is — an address the sweep will not
 * touch (link-local `169.254.x`, a tailnet `100.x`), a port nobody answers
 * on, or a batch of timeouts. Addresses and counts only, never a server's
 * label or id.
 */
export interface SweepReport {
  /** The address expo-network gave, the last `en*` IPv4 on iOS. */
  readonly ownIp: string | null;
  /** "Wi‑Fi", "cellular", …, or null when the state lookup failed. */
  readonly network: string | null;
  readonly port: number;
  readonly timeoutMs: number;
  readonly probed: number;
  /** Descriptor answers: servers listed. */
  readonly servers: number;
  /** Something answered on the port that was not a server. */
  readonly answeredOther: number;
  readonly timedOut: number;
  /** Refused, unreachable, and every other transport failure. */
  readonly failed: number;
  /** The first failure's message, so a "Network request failed" reads as such. */
  readonly failure: string | null;
  readonly aborted: boolean;
  readonly elapsedMs: number;
  /** Set on the sweep that ran again after the session's first found nothing (#787). */
  readonly retried?: boolean;
}

/** How long after a silent first sweep the second one starts. */
export const SWEEP_RETRY_DELAY_MS = 2_000;

/**
 * Whether to sweep once more before saying "No Mac answered" (#787): the
 * session's first sweep on iOS runs while the Local Network prompt is still
 * settling, and every probe it sent before the grant is a miss for good. So
 * a first sweep that probed something, was not stopped, and heard from no
 * server gets one more try after `SWEEP_RETRY_DELAY_MS`; a later sweep, an
 * empty one, or one that found a Mac does not.
 */
export function shouldRetrySweep(input: {
  readonly report: SweepReport;
  readonly firstSweepOfSession: boolean;
}): boolean {
  const { report } = input;
  return (
    input.firstSweepOfSession &&
    !report.aborted &&
    !(report.retried ?? false) &&
    report.probed > 0 &&
    report.servers === 0
  );
}

/** expo-network's `NetworkStateType` as a word for the report. */
export function networkWord(type: string | undefined): string | null {
  switch (type) {
    case undefined:
      return null;
    case "WIFI":
      return "Wi‑Fi";
    case "CELLULAR":
      return "cellular";
    default:
      return type.toLowerCase();
  }
}

export function sweepSummary(report: SweepReport): string {
  const on = report.network === null ? "" : ` on ${report.network}`;
  const subnet = subnetLabel(report.ownIp);
  if (subnet === null) {
    return report.ownIp === null
      ? `Nothing swept: the phone reported no address${on}.`
      : `Nothing swept: ${report.ownIp}${on} is not a private Wi‑Fi address.`;
  }
  const seconds = `${(report.elapsedMs / 1000).toFixed(1)} s`;
  const counts = [
    `${report.probed} probed`,
    `${report.servers} answered`,
    `${report.timedOut} timed out (${report.timeoutMs} ms)`,
    `${report.failed} failed`,
    ...(report.answeredOther > 0 ? [`${report.answeredOther} not a server`] : []),
  ].join(", ");
  const failure = report.failure === null ? "" : ` First failure: ${report.failure}.`;
  const aborted = report.aborted ? " Stopped early." : "";
  const retried = report.retried
    ? ` Second sweep, ${SWEEP_RETRY_DELAY_MS / 1000} s after the first found nothing.`
    : "";
  return `Swept ${subnet} on :${report.port} from ${report.ownIp}${on}: ${counts}, ${seconds}.${failure}${aborted}${retried}`;
}

export function probeUrl(ip: string, port: number = INFINITUS_SERVER_PORT): string {
  return `http://${ip}:${port}${WELL_KNOWN_ENVIRONMENT_PATH}`;
}

/** A `/.well-known/t3/environment` body as a row, or null for anything else
    listening on that port. */
export function nearbyServerFromDescriptor(
  ip: string,
  body: unknown,
  port: number = INFINITUS_SERVER_PORT,
): NearbyServer | null {
  if (typeof body !== "object" || body === null) return null;
  const record = body as Record<string, unknown>;
  if (typeof record.environmentId !== "string" || typeof record.label !== "string") return null;
  const capabilities = record.capabilities;
  const infinitus =
    typeof capabilities === "object" &&
    capabilities !== null &&
    (capabilities as Record<string, unknown>).infinitus === true;
  return {
    environmentId: record.environmentId,
    host: preferredHost(ip, port, record.lanHttpBaseUrls),
    label: record.label,
    infinitus,
  };
}
