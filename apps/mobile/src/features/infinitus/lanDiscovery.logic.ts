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
  /** `ip:port`, what the Host field takes. */
  readonly host: string;
  readonly label: string;
  /** The server reports the Infinitus capability, so it is a fork build. */
  readonly infinitus: boolean;
}

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
  return { host: `${ip}:${port}`, label: record.label, infinitus };
}
