import { signInDismissCommandArgs } from "@infinitus/client-runtime/state/infinitusAccounts";
import type { InfinitusCommandInput, InfinitusSecretInput } from "@infinitus/contracts/infinitus";
import type {
  InfinitusAwsLogin,
  InfinitusAwsLoginAccount,
  InfinitusSnapshot,
} from "@infinitus/contracts/infinitus";

/** One lapsed sign-in as the phone shows it (#572 task 7). Every one of the
    Mac's flows reaches the phone: `--remote` (the page opens in Safari and
    ends with an authorization code pasted back here, then to the Mac over
    `infinitus.secret` — the phone's default, as on the old native phone:
    Safari serves passkeys), the device-code flow (the Mac prints a URL and a
    code, finishes by itself once approved on any device), the relay flow
    (the CLI redirects to a loopback port, which this phone binds itself —
    see `loopbackCatch.ts` — and hands back the same way), and `--local` (the
    Mac opens its own browser). */
export interface SignInModel {
  readonly key: string;
  readonly profile: string;
  readonly provider: "aws" | "gcloud";
  readonly providerLabel: string;
  readonly phase: "idle" | "starting" | "waiting" | "done" | "failed";
  /** The running login's flow, else the one the Mac would start. */
  readonly flow: "remote" | "deviceCode" | "local" | "relay" | "unknown";
  /** The page to open on this phone, when the Mac's flow printed one. */
  readonly url: string | null;
  /** The code the page asks for (device-code flow). */
  readonly userCode: string | null;
  /** The loopback port the relay flow's CLI redirects to, when it is one. */
  readonly callbackPort: number | null;
  /** The account id and user name the AWS page asks for, from the profile's
      config; the user copies them from the card. */
  readonly account: { readonly accountId: string; readonly userName: string | null } | null;
  /** The code flow's code went to the Mac, which is finishing the login
      (`AwsLoginRunner.submit` writes that message, and reads it itself). */
  readonly codeSubmitted: boolean;
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

function flowOf(flow: string): SignInModel["flow"] {
  return flow === "remote" || flow === "deviceCode" || flow === "local" || flow === "relay"
    ? flow
    : "unknown";
}

function accountOf(account: InfinitusAwsLoginAccount | null | undefined): SignInModel["account"] {
  if (account == null || account.accountId === "") return null;
  return { accountId: account.accountId, userName: account.userName || null };
}

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
    flow: flowOf(item.state?.flow ?? item.flow),
    url: item.state?.url ?? null,
    userCode: item.state?.userCode ?? null,
    callbackPort: item.state?.callbackPort ?? null,
    account: accountOf(item.account),
    codeSubmitted: item.state?.message === "code submitted",
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

/** How the phone starts a login. `code`: `--remote`, the page ends with a
    code pasted back here (the Mac keeps an SSO profile on the device-code
    flow whatever is asked). `catch`: no flag, the Mac's own flow — the relay
    one for gcloud and a plain AWS profile, with this phone answering the
    loopback redirect, or the device-code one for an SSO profile. */
export type SignInStartMode = "code" | "catch";

/** Start the sign-in: `aws-login <profile>` (`gcloud-login` for gcloud). */
export function startSignInCommand(
  item: SignInModel,
  mode: SignInStartMode,
): InfinitusCommandInput {
  return {
    command: item.provider === "gcloud" ? "gcloud-login" : "aws-login",
    args: [item.profile],
    options: mode === "code" ? { remote: "true" } : {},
  };
}

/** Forget the login (`--dismiss`): a failed card leaves the list. */
export function dismissSignInCommand(item: SignInModel): InfinitusCommandInput {
  const args = signInDismissCommandArgs(item.provider, item.profile);
  return { command: args.command, args: [...args.args], options: args.options };
}

/** Whether the row can take the code flow: the Mac turns `--remote` into a
    paste-back only where it would otherwise relay, so an SSO profile
    (device-code) never can. A login already running any other flow can —
    the Mac replaces a run of another kind. */
export function signInTakesCode(item: SignInModel): boolean {
  return item.flow !== "deviceCode";
}

/** Hand the pasted code to the Mac: `aws-login-code <profile>` or
    `gcloud-login-code <account>` with the code on stdin — the verb is per
    CLI, and gcloud's positional is spelled `<account|default|application-default>`
    in the manifest, which the secret layer names `account`. */
export function signInCodeSecretArgs(item: SignInModel): Omit<InfinitusSecretInput, "secret"> {
  return item.provider === "gcloud"
    ? { command: "gcloud-login-code", args: { account: item.profile } }
    : { command: "aws-login-code", args: { profile: item.profile } };
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
