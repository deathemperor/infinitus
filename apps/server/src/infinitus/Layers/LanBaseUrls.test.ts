import type * as NodeOS from "node:os";

import { describe, expect, it } from "vite-plus/test";

import { lanHttpBaseUrls } from "./LanBaseUrls.ts";

const iface = (
  address: string,
  family: "IPv4" | "IPv6" = "IPv4",
  internal = false,
): NodeOS.NetworkInterfaceInfo =>
  ({
    address,
    netmask: "",
    family,
    mac: "00:00:00:00:00:00",
    internal,
    cidr: null,
    ...(family === "IPv6" ? { scopeid: 0 } : {}),
  }) as NodeOS.NetworkInterfaceInfo;

const interfaces = {
  lo0: [iface("127.0.0.1", "IPv4", true), iface("::1", "IPv6", true)],
  en0: [iface("192.168.1.20"), iface("fe80::1", "IPv6")],
  utun3: [iface("100.64.0.9")],
  bridge100: [iface("169.254.10.3")],
  en5: [iface("10.0.0.7")],
};

describe("lanHttpBaseUrls", () => {
  it("lists every routable IPv4 on a wildcard bind, private addresses first, on the listening port", () => {
    expect(lanHttpBaseUrls({ host: "0.0.0.0", port: 3773, interfaces })).toEqual([
      "http://192.168.1.20:3773",
      "http://10.0.0.7:3773",
      "http://100.64.0.9:3773",
    ]);
    expect(lanHttpBaseUrls({ host: "::", port: 3773, interfaces })).toHaveLength(3);
  });

  it("names the bound address itself when the bind is one IPv4", () => {
    expect(lanHttpBaseUrls({ host: "192.168.1.20", port: 3773, interfaces })).toEqual([
      "http://192.168.1.20:3773",
    ]);
  });

  it("offers nothing for a loopback bind, an unknown port, or an IPv6 bind", () => {
    expect(lanHttpBaseUrls({ host: undefined, port: 3773, interfaces })).toEqual([]);
    expect(lanHttpBaseUrls({ host: "127.0.0.1", port: 3773, interfaces })).toEqual([]);
    expect(lanHttpBaseUrls({ host: "localhost", port: 3773, interfaces })).toEqual([]);
    expect(lanHttpBaseUrls({ host: "0.0.0.0", port: 0, interfaces })).toEqual([]);
    expect(lanHttpBaseUrls({ host: "fd00::5", port: 3773, interfaces })).toEqual([]);
  });

  it("offers nothing on a host with only loopback", () => {
    expect(
      lanHttpBaseUrls({ host: "0.0.0.0", port: 3773, interfaces: { lo0: interfaces.lo0 } }),
    ).toEqual([]);
  });
});
