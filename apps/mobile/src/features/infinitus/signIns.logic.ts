import type { InfinitusCommandInput, InfinitusSecretInput } from "@t3tools/contracts/infinitus";
import type { InfinitusAwsLogin, InfinitusSnapshot } from "@t3tools/contracts/infinitus";

/** One lapsed sign-in as the phone shows it (#572 task 7). Three of the Mac's
    flows reach the phone: the device-code flow (the Mac prints a URL and a
    code, finishes by itself once approved on any device), the relay flow (the
    CLI redirects to a loopback port, which this phone binds itself — see
    `loopbackCatch.ts` — and hands back over `infinitus.secret`), and `--local`
    (the Mac opens its own browser). `--remote` wants a code typed back into
    the Mac and has no phone surface. */
export interface SignInModel {
  readonly key: string;
  readonly profile: string;
  readonly provider: "aws" | "gcloud";
  readonly providerLabel: string;
  readonly phase: "idle" | "starting" | "waiting" | "done" | "failed";
  /** The page to open on this phone, when the Mac's flow printed one. */
  readonly url: string | null;
  /** The code the page asks for (device-code flow). */
  readonly userCode: string | null;
  /** The loopback port the relay flow's CLI redirects to, when it is one. */
  readonly callbackPort: number | null;
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

const providerOf = (item: InfinitusAwsLogin) => (item.provider === "gcloud" ? "gcloud" : "aws");

/** Which of a profile's entries to draw: a running login first, then anything
    still lapsed, and a finished one last. A `done` entry must never displace an
    idle one — `phaseOf` reads a missing state as idle and a finished login has
    one, so ranking by "has a state" would let the finished entry win and the
    filter below would then drop the profile out of the list entirely, with the
    credentials still expired and no way left to start the login. */
const foldRank = (item: InfinitusAwsLogin) => {
  const phase = phaseOf(item);
  if (phase === "starting" || phase === "waiting") return 0;
  if (phase === "done") return 2;
  return 1;
};

export function signInModel(item: InfinitusAwsLogin): SignInModel {
  const provider = providerOf(item);
  return {
    key: `${provider}:${item.profile}`,
    profile: item.profile,
    provider,
    providerLabel: provider === "gcloud" ? "gcloud" : "AWS",
    phase: phaseOf(item),
    url: item.state?.url ?? null,
    userCode: item.state?.userCode ?? null,
    callbackPort: item.state?.callbackPort ?? null,
    message: item.state?.message ?? null,
  };
}

/** The sign-ins a snapshot asks for, finished ones dropped. Empty when the
    build has no `aws-logins` (the field is absent) or nothing lapsed.
    One row per tool and profile, as the web's list is: the session that hit a
    profile is gone with the Mac's tracker (#1041), so the same profile can
    appear twice with nothing left to tell the rows apart. A group is drawn
    from its running login when one of them has it, else from any entry still
    lapsed, and only from a finished one when that is all there is. */
export function lapsedSignIns(snapshot: InfinitusSnapshot | null): ReadonlyArray<SignInModel> {
  if (snapshot === null || !snapshot.available || snapshot.awsLogins === undefined) return [];
  const byProfile = new Map<string, InfinitusAwsLogin>();
  for (const item of snapshot.awsLogins) {
    const key = `${providerOf(item)}:${item.profile}`;
    const kept = byProfile.get(key);
    if (kept === undefined || foldRank(item) < foldRank(kept)) {
      byProfile.set(key, item);
    }
  }
  return [...byProfile.values()].map(signInModel).filter((item) => item.phase !== "done");
}

/** The headline for one item: which credentials expired, and for what. */
export function signInHeadline(item: SignInModel): string {
  return `Expired ${item.providerLabel} credentials for ${item.profile}.`;
}

/** Start the sign-in: `aws-login <profile>` (`gcloud-login` for gcloud).
    `catching` says this phone can answer the CLI's loopback redirect, so the
    Mac is left to pick its own flow — the relay one for gcloud and for a
    plain AWS profile. Without a catcher that redirect would dead-end in the
    phone's browser, so `--local` sends the person to the Mac instead. */
export function startSignInCommand(item: SignInModel, catching: boolean): InfinitusCommandInput {
  return {
    command: item.provider === "gcloud" ? "gcloud-login" : "aws-login",
    args: [item.profile],
    options: catching ? {} : { local: "true" },
  };
}

/** The loopback port this phone would bind to finish the row's login, or null
    when the Mac's flow does not redirect to one (the device-code flow, a login
    the Mac has not started yet, an app too old to report the port). */
export function signInCallbackPort(item: SignInModel): number | null {
  const port = item.callbackPort;
  if (port === null || !Number.isInteger(port) || port <= 0 || port > 65535) return null;
  return port;
}

/** Hand the intercepted redirect to the Mac: `aws-login-callback <profile>`
    with the whole URL on stdin (one verb for both CLIs — the Mac reads the
    outstanding login to know whose listener to replay it against). The URL
    carries the authorization code, which is why it travels as a secret and
    never as an argument. */
export function signInCallbackSecretArgs(item: SignInModel): Omit<InfinitusSecretInput, "secret"> {
  return { command: "aws-login-callback", args: { profile: item.profile } };
}
