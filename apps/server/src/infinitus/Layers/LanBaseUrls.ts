import * as NodeOS from "node:os";

import { isLoopbackHost, isWildcardHost } from "../../startupAccess.ts";

type NetworkInterfacesMap = ReturnType<typeof NodeOS.networkInterfaces>;

const PRIVATE_IPV4 = /^(10\.\d+|172\.(1[6-9]|2\d|3[01])|192\.168)\.\d+\.\d+$/;
const LINK_LOCAL_IPV4 = /^169\.254\./;

/**
 * The base URLs a phone on the Mac's own network can dial (#651): the
 * listening port on every non-internal IPv4 address of the host while the
 * server listens beyond loopback. A loopback bind, a port not yet known
 * (0) or a host with no such address yields none. Private addresses come
 * first — the Devices card encodes the first one; anything link-local is
 * left out (nothing routes to it). Plain http: the LAN has no certificate.
 */
export function lanHttpBaseUrls(input: {
  readonly host: string | undefined;
  readonly port: number;
  readonly interfaces?: NetworkInterfacesMap;
}): ReadonlyArray<string> {
  if (input.port <= 0 || isLoopbackHost(input.host)) return [];
  const host = input.host as string;
  if (!isWildcardHost(host)) {
    return host.includes(":") ? [] : [`http://${host}:${input.port}`];
  }
  const addresses = Object.values(input.interfaces ?? NodeOS.networkInterfaces())
    .flatMap((entries) => entries ?? [])
    .filter(
      (entry) =>
        !entry.internal &&
        (entry.family === "IPv4" || (entry.family as unknown) === 4) &&
        !LINK_LOCAL_IPV4.test(entry.address),
    )
    .map((entry) => entry.address);
  const ordered = [
    ...addresses.filter((address) => PRIVATE_IPV4.test(address)),
    ...addresses.filter((address) => !PRIVATE_IPV4.test(address)),
  ];
  return [...new Set(ordered)].map((address) => `http://${address}:${input.port}`);
}
