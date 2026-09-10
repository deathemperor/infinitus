import type { InfinitusCommandInput } from "@t3tools/contracts/infinitus";
import type { InfinitusAwsLogin, InfinitusSnapshot } from "@t3tools/contracts/infinitus";

/** One lapsed sign-in as the phone shows it (#572 task 7). Through the fork's
    RPC only two of the Mac's flows are reachable: the device-code flow (the
    Mac prints a URL and a code, finishes by itself once approved on any
    device) and `--local` (the Mac opens its own browser). The relay and
    `--remote` flows need a callback URL or a code fed to the Mac over stdin,
    which the RPC deliberately never carries. */
export interface SignInModel {
  readonly key: string;
  readonly profile: string;
  readonly provider: "aws" | "gcloud";
  readonly providerLabel: string;
  readonly sessionLabel: string | null;
  readonly pid: number | null;
  readonly phase: "idle" | "starting" | "waiting" | "done" | "failed";
  /** The page to open on this phone, when the Mac's flow printed one. */
  readonly url: string | null;
  /** The code the page asks for (device-code flow). */
  readonly userCode: string | null;
  readonly message: string | null;
}

function phaseOf(item: InfinitusAwsLogin): SignInModel["phase"] {
  const phase = item.state?.phase;
  if (phase === undefined || phase === null) return "idle";
  if (phase === "starting") return "starting";
  if (phase === "waitingForBrowser" || phase === "waitingForCode") return "waiting";
  if (phase === "done") return "done";
  if (phase === "failed") return "failed";
  return "waiting";
}

export function signInModel(item: InfinitusAwsLogin): SignInModel {
  const provider = item.provider === "gcloud" ? "gcloud" : "aws";
  return {
    key: `${provider}:${item.profile}|${item.pid ?? 0}`,
    profile: item.profile,
    provider,
    providerLabel: provider === "gcloud" ? "gcloud" : "AWS",
    sessionLabel: item.sessionLabel ?? null,
    pid: item.pid ?? null,
    phase: phaseOf(item),
    url: item.state?.url ?? null,
    userCode: item.state?.userCode ?? null,
    message: item.state?.message ?? null,
  };
}

/** The sign-ins a snapshot asks for, finished ones dropped. Empty when the
    build has no `aws-logins` (the field is absent) or nothing lapsed. */
export function lapsedSignIns(snapshot: InfinitusSnapshot | null): ReadonlyArray<SignInModel> {
  if (snapshot === null || !snapshot.available || snapshot.awsLogins === undefined) return [];
  return snapshot.awsLogins.map(signInModel).filter((item) => item.phase !== "done");
}

/** The headline for one item: which session is stuck and on what. */
export function signInHeadline(item: SignInModel): string {
  const subject = `${item.providerLabel} credentials for ${item.profile}`;
  return item.sessionLabel
    ? `${item.sessionLabel} is stuck on expired ${subject}.`
    : `Expired ${subject}.`;
}

/** Start the sign-in on the Mac's own browser: `aws-login <profile> --local`
    (`gcloud-login` for gcloud), scoped to the session that hit it. */
export function startSignInCommand(item: SignInModel): InfinitusCommandInput {
  return {
    command: item.provider === "gcloud" ? "gcloud-login" : "aws-login",
    args: [item.profile],
    options: item.pid === null ? { local: "true" } : { local: "true", pid: String(item.pid) },
  };
}
