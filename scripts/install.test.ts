// @effect-diagnostics nodeBuiltinImport:off - Drives the real shell installer against a local GitHub fixture.
import * as HostProcess from "@infinitus/shared/HostProcess";
import * as NodeChildProcess from "node:child_process";
import * as NodeFSP from "node:fs/promises";
import * as NodeHttp from "node:http";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import { describe, expect, it } from "vite-plus/test";

// Fork: this repository's releases are one `v<VERSION>` train; the installer takes the newest tag
// without a nightly or preview suffix from the API list and refuses the other channels.
const releases = [
  { tag_name: "v0.5.0-alpha.40-infinitus-nightly.20261025.12" },
  { tag_name: "v1.2.4-preview.20261019.50" },
  { tag_name: "v0.5.0-alpha.39" },
  { tag_name: "v0.5.0-alpha.38" },
];

const runInstaller = async (channel: string, version: string) => {
  const root = await NodeFSP.mkdtemp(NodePath.join(NodeOS.tmpdir(), "infinitus-install-index-"));
  const target = NodePath.join(root, "home/runtime/versions", version);
  const server = NodeHttp.createServer((request, response) => {
    const url = new URL(request.url ?? "/", "http://fixture");
    const body = url.pathname === "/repos/deathemperor/infinitus/releases" ? releases : undefined;
    if (body === undefined) response.statusCode = 404;
    // The API pretty-prints and the installer reads it line by line.
    response.end(JSON.stringify(body ?? [], null, 2));
  });
  try {
    // An existing completed install isolates release resolution from archive downloads.
    await NodeFSP.mkdir(target, { recursive: true });
    await NodeFSP.writeFile(NodePath.join(target, ".install-complete"), `${version}\n`);
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("Expected a TCP listener");
    const origin = `http://127.0.0.1:${address.port}`;
    const source = await NodeFSP.readFile(
      NodePath.resolve(import.meta.dirname, "install.sh"),
      "utf8",
    );
    const installer = NodePath.join(root, "install.sh");
    await NodeFSP.writeFile(installer, source.replace(/https:\/\/(api\.)?github\.com/g, origin));
    return await new Promise<{ code: number | null; output: string }>((resolve, reject) => {
      const child = NodeChildProcess.spawn("sh", [installer], {
        env: {
          ...process.env,
          T3CODE_VERSION: "",
          T3CODE_CHANNEL: channel,
          T3CODE_HOME: NodePath.join(root, "home"),
          T3CODE_INSTALL_BIN_DIR: NodePath.join(root, "bin"),
          // A wrong version must fail here instead of downloading a real release.
          T3CODE_RELEASE_BASE_URL: origin,
        },
        stdio: ["ignore", "pipe", "pipe"],
      });
      let output = "";
      child.stdout.on("data", (chunk: Buffer) => (output += chunk.toString()));
      child.stderr.on("data", (chunk: Buffer) => (output += chunk.toString()));
      child.on("error", reject);
      child.on("close", (code) => resolve({ code, output }));
    });
  } finally {
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    await NodeFSP.rm(root, { recursive: true, force: true });
  }
};

describe.skipIf(HostProcess.Platform.defaultValue() !== "linux")("installer channel lookup", () => {
  it("finds the newest release-train tag behind nightly and preview builds", async () => {
    const { code, output } = await runInstaller("stable", "0.5.0-alpha.39");
    expect(code, output).toBe(0);
    expect(output).toContain("Installed Infinitus 0.5.0-alpha.39");
  });

  it("refuses the preview channel, which this repository never publishes", async () => {
    const { code, output } = await runInstaller("preview", "1.2.4-preview.20261019.50");
    expect(code).not.toBe(0);
    expect(output).toContain("publishes no preview server archive");
  });
});
