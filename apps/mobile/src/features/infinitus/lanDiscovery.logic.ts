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
