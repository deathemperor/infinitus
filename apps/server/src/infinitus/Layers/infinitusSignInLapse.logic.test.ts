import type { ProviderRuntimeEvent } from "@infinitus/contracts";
import { describe, expect, it } from "vite-plus/test";

import {
  hasLoginInFlight,
  manifestHasVerb,
  signInLapse,
  signInLapseFromEvent,
  signInMarkerSummary,
  signInRun,
  signInVerb,
} from "./infinitusSignInLapse.logic.ts";

const SSO_EXPIRED = "Error when retrieving token from sso: Token has expired and refresh failed\n";
const BROKER = "[aws-cred-broker] refresh failed for prod\n  Fix: aws login --profile prod\n";
const GCLOUD_TOKENS =
  "ERROR: (gcloud.auth.print-access-token) There was a problem refreshing your current auth tokens: invalid_grant\n" +
  "Please run:\n\n  $ gcloud auth login\n\nto obtain new credentials.\n";
const GCLOUD_ADC =
  "google.auth.exceptions.DefaultCredentialsError: Your default credentials were not found. To set up Application Default Credentials, see https://cloud.google.com/docs/authentication/external/set-up-adc\n";

describe("signInLapse (#1076)", () => {
  it("reads the CLI's expired-session error, the profile from the failed command", () => {
    expect(signInLapse(SSO_EXPIRED)).toEqual({ provider: "aws", profile: "default" });
    expect(signInLapse(SSO_EXPIRED, "aws s3 ls --profile papaya")).toEqual({
      provider: "aws",
      profile: "papaya",
    });
    expect(signInLapse(SSO_EXPIRED, "AWS_PROFILE=banyan aws sts get-caller-identity")).toEqual({
      provider: "aws",
      profile: "banyan",
    });
  });

  it("takes the profile the error itself names over the command's", () => {
    expect(signInLapse(BROKER, "aws s3 ls --profile other")).toEqual({
      provider: "aws",
      profile: "prod",
    });
  });

  it("ignores the same words quoted from a file or a grep hit", () => {
    const read = '   241\t    "the sso session has expired",\n   242\t    "fix: aws login",\n';
    expect(signInLapse(read)).toBeNull();
    const grep = 'AwsLogin.swift:250:        "  fix: aws login",\n';
    expect(signInLapse(grep)).toBeNull();
    expect(signInLapse("all good\n")).toBeNull();
  });

  it("reads gcloud's lapsed account and its Application Default Credentials apart", () => {
    expect(signInLapse(GCLOUD_TOKENS)).toEqual({ provider: "gcloud", profile: "default" });
    expect(signInLapse(GCLOUD_TOKENS, "gcloud projects list --account ci-bot")).toEqual({
      provider: "gcloud",
      profile: "ci-bot",
    });
    expect(signInLapse(GCLOUD_TOKENS, "CLOUDSDK_CORE_ACCOUNT=ci-bot gcloud projects list")).toEqual(
      { provider: "gcloud", profile: "ci-bot" },
    );
    // ADC is its own credential, whatever account the command named.
    expect(signInLapse(GCLOUD_ADC, "gcloud storage ls --account ci-bot")).toEqual({
      provider: "gcloud",
      profile: "application-default",
    });
  });

  it("finds the failure at the end of a long result", () => {
    expect(signInLapse("x".repeat(200_000) + "\n" + SSO_EXPIRED)).toEqual({
      provider: "aws",
      profile: "default",
    });
  });
});

const itemUpdated = (data: unknown): ProviderRuntimeEvent =>
  ({
    type: "item.updated",
    eventId: "evt-1",
    provider: "claude",
    createdAt: "2026-09-13T00:00:00Z",
    threadId: "thread-1",
    itemId: "item-1",
    payload: { itemType: "tool", status: "failed", data },
  }) as never;

describe("signInLapseFromEvent (#1076)", () => {
  it("reads the Claude driver's relayed tool result and the Bash command beside it", () => {
    const event = itemUpdated({
      toolName: "Bash",
      input: { command: "aws s3 ls --profile papaya" },
      result: {
        type: "tool_result",
        tool_use_id: "tu-1",
        content: [{ type: "text", text: SSO_EXPIRED }],
        is_error: true,
      },
    });
    expect(signInLapseFromEvent(event)).toEqual({ provider: "aws", profile: "papaya" });
    const plain = itemUpdated({
      toolName: "Bash",
      input: { command: "gcloud auth print-access-token" },
      result: { type: "tool_result", tool_use_id: "tu-2", content: GCLOUD_TOKENS },
    });
    expect(signInLapseFromEvent(plain)).toEqual({ provider: "gcloud", profile: "default" });
  });

  it("is null for every other event and for a result that is not a tool result", () => {
    expect(signInLapseFromEvent(itemUpdated({ toolName: "Read", input: {} }))).toBeNull();
    expect(
      signInLapseFromEvent(itemUpdated({ result: { type: "text", text: SSO_EXPIRED } })),
    ).toBeNull();
    expect(
      signInLapseFromEvent({ ...itemUpdated(undefined), type: "item.completed" } as never),
    ).toBeNull();
  });
});

describe("signInRun", () => {
  it("reads a login the command runs itself, and the profile it names", () => {
    expect(
      signInRun(
        "cp ~/.aws/config ~/.aws/config.bak-$(date +%s) && aws login --profile papaya-login 2>&1 | tail -5; AWS_PROFILE=papaya aws sts get-caller-identity",
      ),
    ).toEqual({ provider: "aws", profile: "papaya-login" });
    expect(signInRun("AWS_PROFILE=banyan aws sso login")).toEqual({
      provider: "aws",
      profile: "banyan",
    });
    expect(signInRun("aws login")).toEqual({ provider: "aws", profile: "default" });
    expect(signInRun("cd /tmp && gcloud auth application-default login")).toEqual({
      provider: "gcloud",
      profile: "application-default",
    });
    expect(signInRun("gcloud auth login me@example.com --no-launch-browser")).toEqual({
      provider: "gcloud",
      profile: "me@example.com",
    });
  });

  it("ignores the words searched for, echoed or passed as a message", () => {
    expect(signInRun("git grep -il \"aws login\\|awsLogin\" -- ':!.repos' | head -40")).toBeNull();
    expect(signInRun('echo "run: aws login --profile papaya"')).toBeNull();
    expect(signInRun("git commit -m 'fix: aws login card'")).toBeNull();
    expect(signInRun("grep -rn aws login src")).toBeNull();
    expect(signInRun("AWS_PROFILE=papaya aws sts get-caller-identity")).toBeNull();
  });

  it("is read off a tool's start, the event with an input and no result yet", () => {
    expect(
      signInLapseFromEvent(
        itemUpdated({ toolName: "Bash", input: { command: "aws login --profile papaya-login" } }),
      ),
    ).toEqual({ provider: "aws", profile: "papaya-login" });
    expect(signInLapseFromEvent(itemUpdated({ toolName: "Bash", input: {} }))).toBeNull();
  });
});

describe("the row and the verb (#1076)", () => {
  it("words the summary and names the Mac's verb", () => {
    expect(signInMarkerSummary({ provider: "aws", profile: "papaya" })).toBe(
      "AWS sign-in needed on papaya",
    );
    expect(signInMarkerSummary({ provider: "gcloud", profile: "application-default" })).toBe(
      "gcloud sign-in needed on application-default",
    );
    expect(signInVerb("aws")).toBe("aws-login");
    expect(signInVerb("gcloud")).toBe("gcloud-login");
    const command = {
      name: "aws-login",
      args: [],
      options: [],
      effect: "human",
      summary: "",
      replyShape: "",
    };
    expect(manifestHasVerb([command as never], "aws-login")).toBe(true);
    expect(manifestHasVerb([command as never], "gcloud-login")).toBe(false);
  });
});

describe("hasLoginInFlight (#1076)", () => {
  const state = (phase: string) => ({ profile: "papaya", flow: "local", phase, startedAt: 0 });
  const aws = { provider: "aws", profile: "papaya" } as const;

  it("counts a login still waiting on a person, whatever the phase", () => {
    for (const phase of ["starting", "waitingForBrowser", "waitingForCode"]) {
      expect(hasLoginInFlight([{ profile: "papaya", state: state(phase) }], aws)).toBe(true);
    }
  });

  it("does not count a login that ended, one with no state, or another credential", () => {
    expect(hasLoginInFlight([{ profile: "papaya", state: state("done") }], aws)).toBe(false);
    expect(hasLoginInFlight([{ profile: "papaya", state: state("failed") }], aws)).toBe(false);
    expect(hasLoginInFlight([{ profile: "papaya" }], aws)).toBe(false);
    expect(hasLoginInFlight([{ profile: "banyan", state: state("starting") }], aws)).toBe(false);
    expect(
      hasLoginInFlight([{ profile: "papaya", provider: "gcloud", state: state("starting") }], aws),
    ).toBe(false);
    expect(hasLoginInFlight([], aws)).toBe(false);
  });

  it("reads a missing provider as AWS and matches gcloud on its own name", () => {
    const gcloud = { provider: "gcloud", profile: "papaya" } as const;
    expect(
      hasLoginInFlight(
        [{ profile: "papaya", provider: "gcloud", state: state("waitingForCode") }],
        gcloud,
      ),
    ).toBe(true);
    expect(hasLoginInFlight([{ profile: "papaya", state: state("starting") }], gcloud)).toBe(false);
    expect(
      hasLoginInFlight([{ profile: "papaya", provider: null, state: state("starting") }], aws),
    ).toBe(true);
  });
});
