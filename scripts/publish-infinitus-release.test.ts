import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vite-plus/test";

const script = fileURLToPath(new URL("./publish-infinitus-release.sh", import.meta.url));
const temporary: string[] = [];
afterEach(() => {
  for (const path of temporary.splice(0)) rmSync(path, { recursive: true, force: true });
});

function fixture() {
  const root = mkdtempSync(join(tmpdir(), "infinitus-publish-"));
  temporary.push(root);
  const bin = join(root, "bin");
  const assets = join(root, "assets");
  mkdirSync(bin);
  mkdirSync(assets);
  writeFileSync(join(assets, "a.zip"), "first signed artifact");
  writeFileSync(join(assets, "b.zip"), "second signed artifact");
  const notes = join(root, "notes.md");
  writeFileSync(notes, "Release notes");
  const state = join(root, "state.json");
  writeFileSync(state, JSON.stringify({ exists: false, assets: [], uploads: [], edits: 0 }));
  writeFileSync(
    join(bin, "gh"),
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
  writeFileSync(join(bin, "sleep"), "#!/bin/sh\nexit 0\n", { mode: 0o755 });
  writeFileSync(join(bin, "timeout"), '#!/bin/sh\nshift\nexec "$@"\n', { mode: 0o755 });
  const read = () =>
    JSON.parse(readFileSync(state, "utf8")) as {
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
      spawnSync("bash", [script, assets, notes], {
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

describe.skipIf(process.platform === "win32")("release publication", () => {
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
    writeFileSync(join(f.assets, "a.zip"), "different artifact");
    expect(f.run().status).toBe(1);
    expect(f.read().uploads).toEqual(uploads);
    writeFileSync(
      f.state,
      JSON.stringify({ ...f.read(), exists: true, isDraft: true, targetCommitish: "other-commit" }),
    );
    expect(f.run().status).toBe(1);
    expect(f.read().uploads).toEqual(uploads);
  });

  it("has valid shell syntax", () => {
    expect(() => execFileSync("bash", ["-n", script])).not.toThrow();
  });
});
