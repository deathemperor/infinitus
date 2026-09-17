// @effect-diagnostics nodeBuiltinImport:off - Runs the real shell publisher against a disposable on-disk CLI fixture.
import * as NodeChildProcess from "node:child_process";
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import * as NodeURL from "node:url";
import { afterEach, describe, expect, it } from "vite-plus/test";

const script = NodeURL.fileURLToPath(new URL("./publish-infinitus-release.sh", import.meta.url));
const temporary: string[] = [];
afterEach(() => {
  for (const path of temporary.splice(0)) NodeFS.rmSync(path, { recursive: true, force: true });
});

function fixture() {
  const root = NodeFS.mkdtempSync(NodePath.join(NodeOS.tmpdir(), "infinitus-publish-"));
  temporary.push(root);
  const bin = NodePath.join(root, "bin");
  const assets = NodePath.join(root, "assets");
  NodeFS.mkdirSync(bin);
  NodeFS.mkdirSync(assets);
  NodeFS.writeFileSync(NodePath.join(assets, "a.zip"), "first signed artifact");
  NodeFS.writeFileSync(NodePath.join(assets, "b.zip"), "second signed artifact");
  const notes = NodePath.join(root, "notes.md");
  NodeFS.writeFileSync(notes, "Release notes");
  const state = NodePath.join(root, "state.json");
  NodeFS.writeFileSync(state, JSON.stringify({ exists: false, assets: [], uploads: [], edits: 0 }));
  NodeFS.writeFileSync(
    NodePath.join(bin, "gh"),
    `#!/usr/bin/env node
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const args = process.argv.slice(2);
const file = process.env.TEST_STATE;
const state = JSON.parse(fs.readFileSync(file, "utf8"));
const save = () => fs.writeFileSync(file, JSON.stringify(state));
switch (args[1]) {
  case "view":
    if (!state.exists) process.exit(1);
    console.log(JSON.stringify(state));
    break;
  case "create":
    state.exists = true; state.isDraft = true; state.targetCommitish = process.env.GITHUB_SHA;
    save(); break;
  case "upload": {
    const asset = args[3];
    const name = path.basename(asset);
    state.uploads.push(name); save();
    if (process.env.TEST_FAILURE === "before-save" && name === "b.zip") process.exit(1);
    const digest = "sha256:" + crypto.createHash("sha256").update(fs.readFileSync(asset)).digest("hex");
    state.assets = state.assets.filter((entry) => entry.name !== name);
    state.assets.push({ name, digest }); save();
    // GitHub can commit the upload, then return an error to the client.
    if (process.env.TEST_FAILURE === "after-save") process.exit(1);
    break;
  }
  case "edit": state.isDraft = false; state.edits += 1; save(); break;
  default: process.exit(2);
}
`,
    { mode: 0o755 },
  );
  NodeFS.writeFileSync(NodePath.join(bin, "sleep"), "#!/bin/sh\nexit 0\n", { mode: 0o755 });
  NodeFS.writeFileSync(NodePath.join(bin, "timeout"), '#!/bin/sh\nshift\nexec "$@"\n', {
    mode: 0o755,
  });
  const read = () =>
    JSON.parse(NodeFS.readFileSync(state, "utf8")) as {
      isDraft: boolean;
      targetCommitish: string;
      uploads: string[];
      edits: number;
      assets: Array<{ name: string; digest: string }>;
    };
  return {
    assets,
    state,
    read,
    run: (failure = "") =>
      NodeChildProcess.spawnSync("bash", [script, assets, notes], {
        env: {
          ...process.env,
          PATH: `${bin}:${process.env.PATH}`,
          TEST_STATE: state,
          TEST_FAILURE: failure,
          GITHUB_REPOSITORY: "test/repo",
          GITHUB_REF_NAME: "v1.0.0-alpha.1",
          GITHUB_SHA: "release-commit",
          VERSION: "1.0.0-alpha.1",
        },
        encoding: "utf8",
        timeout: 15_000,
      }),
  };
}

describe("release publication", () => {
  it("retains completed assets on failure and resumes the draft on rerun", () => {
    const f = fixture();
    const failed = f.run("before-save");
    expect(failed.status, failed.stderr).toBe(1);
    expect(f.read().isDraft).toBe(true);
    expect(f.read().assets.map((asset) => asset.name)).toEqual(["a.zip"]);
    const firstUploads = f.read().uploads.filter((name) => name === "a.zip").length;
    const retry = f.run();
    expect(retry.status, retry.stderr).toBe(0);
    expect(f.read().isDraft).toBe(false);
    expect(f.read().assets.map((asset) => asset.name)).toEqual(["a.zip", "b.zip"]);
    expect(f.read().uploads.filter((name) => name === "a.zip")).toHaveLength(firstUploads);
  });

  it("accepts an upload that saved correctly despite the failed HTTP response", () => {
    const f = fixture();
    const result = f.run("after-save");
    expect(result.status, result.stderr).toBe(0);
    expect(f.read().isDraft).toBe(false);
    expect(f.read().uploads).toEqual(["a.zip", "b.zip"]);
  });

  it("does not replace a published artifact or a different commit's draft", () => {
    const f = fixture();
    expect(f.run().status).toBe(0);
    const uploads = f.read().uploads;
    NodeFS.writeFileSync(NodePath.join(f.assets, "a.zip"), "different artifact");
    expect(f.run().status).toBe(1);
    expect(f.read().uploads).toEqual(uploads);
    NodeFS.writeFileSync(
      f.state,
      JSON.stringify({ ...f.read(), exists: true, isDraft: true, targetCommitish: "other-commit" }),
    );
    expect(f.run().status).toBe(1);
    expect(f.read().uploads).toEqual(uploads);
  });

  it("has valid shell syntax", () => {
    expect(() => NodeChildProcess.execFileSync("bash", ["-n", script])).not.toThrow();
  });
});
