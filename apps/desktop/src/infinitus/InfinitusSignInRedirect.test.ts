// @effect-diagnostics nodeBuiltinImport:off -- The stand-in listener is exercised over a real socket.

import * as NodeHttp from "node:http";
import * as NodeNet from "node:net";

import { describe, expect, it, vi } from "vite-plus/test";

import { listenForSignInRedirect, signInRedirectResponse } from "./InfinitusSignInRedirect.ts";

vi.mock("electron", () => ({ shell: { openExternal: vi.fn() } }));

/** A port nothing holds right now. */
const freePort = () =>
  new Promise<number>((resolve, reject) => {
    const probe = NodeNet.createServer();
    probe.listen(0, "127.0.0.1", () => {
      const address = probe.address();
      probe.close(() => {
        if (typeof address === "object" && address !== null) resolve(address.port);
        else reject(new Error("no port"));
      });
    });
  });

const get = (url: string) =>
  new Promise<{ status: number; body: string }>((resolve, reject) => {
    // A fresh connection every time: a kept-alive socket could reach a server
    // that is closing, and the refused connect below is the point.
    NodeHttp.get(url, { agent: false }, (response) => {
      let body = "";
      response.setEncoding("utf8");
      response.on("data", (chunk: string) => {
        body += chunk;
      });
      response.on("end", () => resolve({ status: response.statusCode ?? 0, body }));
    }).once("error", reject);
  });

describe("signInRedirectResponse", () => {
  it("answers the callback the way the engine would and hands on the address", () => {
    expect(signInRedirectResponse("/callback?code=abc&state=st")).toEqual({
      status: 200,
      body: "Signed in. You can close this window.",
      redirect: "/callback?code=abc&state=st",
    });
    expect(signInRedirectResponse("/callback?error=access_denied&state=st")).toMatchObject({
      status: 200,
      body: "Sign-in failed. You can close this window.",
      redirect: "/callback?error=access_denied&state=st",
    });
  });

  it("ignores anything that is not the callback", () => {
    expect(signInRedirectResponse("/favicon.ico")).toEqual({
      status: 404,
      body: "Not found.",
      redirect: null,
    });
    expect(signInRedirectResponse("/")).toMatchObject({ redirect: null });
  });
});

describe("listenForSignInRedirect", () => {
  it("takes the port, answers the browser once, and settles with the whole address", async () => {
    const port = await freePort();
    const listener = listenForSignInRedirect({ port, hosts: ["127.0.0.1"] });
    const probe = await get(`http://127.0.0.1:${port}/favicon.ico`);
    expect(probe.status).toBe(404);
    const landed = await get(`http://127.0.0.1:${port}/callback?code=abc%2Fd&state=st`);
    expect(landed.status).toBe(200);
    expect(landed.body).toContain("Signed in.");
    await expect(listener.result).resolves.toEqual({
      ok: true,
      redirect: `http://localhost:${port}/callback?code=abc%2Fd&state=st`,
    });
    // Closed with the answer: the port is free again.
    await expect(get(`http://127.0.0.1:${port}/callback?code=x`)).rejects.toMatchObject({
      code: "ECONNREFUSED",
    });
  });

  it("says so when the port is held, and settles plainly when stopped", async () => {
    const port = await freePort();
    const holder = NodeHttp.createServer(() => undefined);
    await new Promise<void>((resolve) => holder.listen(port, "127.0.0.1", resolve));
    try {
      const refused = listenForSignInRedirect({ port, hosts: ["127.0.0.1"] });
      await expect(refused.result).resolves.toEqual({
        ok: false,
        error: `Port ${port} is in use on this machine, so the sign-in cannot end here.`,
      });
    } finally {
      await new Promise<void>((resolve) => holder.close(() => resolve()));
    }
    const stopped = listenForSignInRedirect({ port, hosts: ["127.0.0.1"] });
    stopped.stop();
    await expect(stopped.result).resolves.toEqual({ ok: false });
  });
});
