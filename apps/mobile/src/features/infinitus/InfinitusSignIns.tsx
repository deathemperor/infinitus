import { useAtomValue } from "@effect/atom-react";
import * as Redacted from "effect/Redacted";
import * as Clipboard from "expo-clipboard";
import * as WebBrowser from "expo-web-browser";
import { useMemo, useState } from "react";
import { Linking, Pressable, View } from "react-native";

import { AppText as Text, AppTextInput as TextInput } from "../../components/AppText";
import { cn } from "../../lib/cn";
import { copyTextWithHaptic } from "../../lib/copyTextWithHaptic";
import { infinitusEnvironment } from "../../state/infinitus";
import { environmentPresentations } from "../../state/presentation";
import { useEnvironmentQuery } from "../../state/query";
import { environmentServerConfigsAtom } from "../../state/server";
import { useAtomCommand } from "../../state/use-atom-command";
import {
  commandFailureMessage,
  type InfinitusMac,
  infinitusMacs,
} from "../accounts/accountsRoute.logic";
import {
  awaitLoopbackRedirect,
  listenForLoopbackRedirect,
  loopbackCatchSupported,
  stopLoopbackCatch,
} from "./loopbackCatch";
import {
  isValidSignInCode,
  lapsedSignIns,
  type SignInModel,
  type SignInStartMode,
  signInCallbackPort,
  signInCallbackSecretArgs,
  signInCodeSecretArgs,
  signInHeadline,
  signInTakesCode,
  startSignInCommand,
} from "./signIns.logic";

/** Every paired Mac's lapsed AWS / gcloud sign-ins as cards (#572 task 7):
    on Home above the thread list, and in Settings › Accounts. Renders
    nothing when no Mac reports one. */
export function InfinitusSignIns(props: { readonly className?: string }) {
  const configs = useAtomValue(environmentServerConfigsAtom);
  const presentations = useAtomValue(environmentPresentations.presentationsAtom);
  const macs = useMemo(() => infinitusMacs(configs, presentations), [configs, presentations]);
  if (macs.length === 0) return null;
  return (
    <View className={cn("gap-3", props.className)}>
      {macs.map((mac) => (
        <MacSignIns key={mac.environmentId} mac={mac} />
      ))}
    </View>
  );
}

function MacSignIns(props: { readonly mac: InfinitusMac }) {
  const view = useEnvironmentQuery(
    infinitusEnvironment.snapshot({ environmentId: props.mac.environmentId, input: {} }),
  );
  const items = lapsedSignIns(view.data);
  if (items.length === 0) return null;
  return (
    <>
      {items.map((item) => (
        <SignInCard key={item.key} mac={props.mac} item={item} />
      ))}
    </>
  );
}

function SignInCard(props: { readonly mac: InfinitusMac; readonly item: SignInModel }) {
  const { mac, item } = props;
  const run = useAtomCommand(infinitusEnvironment.command, { reportFailure: false });
  const runSecret = useAtomCommand(infinitusEnvironment.secret, { reportFailure: false });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [code, setCode] = useState("");
  /** The code went to the Mac; the CLI is finishing. */
  const [codeSent, setCodeSent] = useState(false);
  /** The last value copied — its row shows a check until another is. */
  const [copied, setCopied] = useState<string | null>(null);

  const running = item.phase === "starting" || item.phase === "waiting";
  const takesCode = signInTakesCode(item);
  // The relay flow's redirect can be answered here (`loopbackCatch.ts`); the
  // code flow needs no catcher, and is the default as on the old native phone.
  const catchPort =
    loopbackCatchSupported && item.flow === "relay" ? signInCallbackPort(item) : null;
  const primaryMode: SignInStartMode = takesCode ? "code" : "catch";
  const pasteBack = item.flow === "remote" && item.phase === "waiting" && item.url !== null;

  const start = async (mode: SignInStartMode) => {
    setBusy(true);
    setError(null);
    setCodeSent(false);
    const result = await run({
      environmentId: mac.environmentId,
      input: startSignInCommand(item, mode),
    });
    setBusy(false);
    if (result._tag !== "Success") setError(commandFailureMessage(result.cause));
  };

  /** Hand the pasted authorization code to the Mac, which writes it to the
      waiting CLI. Cleared from the field on send; never logged. */
  const sendCode = async () => {
    const trimmed = code.trim();
    if (!isValidSignInCode(trimmed)) {
      setError("That doesn't look like an authorization code.");
      return;
    }
    setBusy(true);
    setError(null);
    const answer = await runSecret({
      environmentId: mac.environmentId,
      input: { ...signInCodeSecretArgs(item), secret: Redacted.make(trimmed) },
    });
    setBusy(false);
    if (answer._tag !== "Success") {
      setError(commandFailureMessage(answer.cause));
      return;
    }
    setCode("");
    setCodeSent(true);
  };

  const pasteCode = async () => {
    const text = await Clipboard.getStringAsync().catch(() => "");
    if (text.trim() !== "") setCode(text.trim());
  };

  /** Open the sign-in page with this phone listening on the port the CLI
      redirects to, and hand the Mac the whole intercepted URL. The sheet stays
      in the app, so the catch happens while it is still up; dismissing it
      cancels the wait and gives the port back. */
  const openCatching = async (url: string, port: number) => {
    setBusy(true);
    setError(null);
    try {
      await listenForLoopbackRedirect(port);
    } catch (cause) {
      setBusy(false);
      setError(cause instanceof Error ? cause.message : `Could not listen on port ${port}.`);
      return;
    }
    const redirect = awaitLoopbackRedirect();
    void WebBrowser.openBrowserAsync(url).finally(() => void stopLoopbackCatch());
    const caught = await redirect;
    void WebBrowser.dismissBrowser();
    if (caught === null) {
      setBusy(false);
      return;
    }
    const answer = await runSecret({
      environmentId: mac.environmentId,
      input: { ...signInCallbackSecretArgs(item), secret: Redacted.make(caught) },
    });
    setBusy(false);
    if (answer._tag !== "Success") setError(commandFailureMessage(answer.cause));
  };

  const openPage = (url: string) => {
    if (catchPort === null) {
      void Linking.openURL(url);
      return;
    }
    void openCatching(url, catchPort);
  };

  const copyRow = (label: string, value: string) => (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={`Copy ${label.toLowerCase()} ${value}`}
      onPress={() => {
        copyTextWithHaptic(value, { target: label.toLowerCase() });
        setCopied(value);
      }}
      className="flex-row items-center gap-2 active:opacity-70"
    >
      <Text className="w-16 text-xs text-warning-foreground">{label}</Text>
      <Text
        numberOfLines={1}
        ellipsizeMode="middle"
        className="flex-1 font-mono text-xs text-warning-foreground"
      >
        {value}
      </Text>
      <Text className="text-xs text-warning-foreground">
        {copied === value ? "Copied" : "Copy"}
      </Text>
    </Pressable>
  );

  const helper =
    item.phase === "starting"
      ? `${mac.label} is starting the sign-in…`
      : pasteBack
        ? codeSent
          ? "Finishing… the Mac is signing in with your code."
          : "Open the sign-in page in Safari; it ends with a code to paste back here."
        : item.phase === "waiting" && item.url !== null
          ? catchPort !== null
            ? "Open the sign-in page here — this phone hands the result back to the Mac."
            : "Open the sign-in page; the Mac finishes by itself once you approve."
          : item.phase === "waiting"
            ? `${mac.label} is waiting for the sign-in to finish in its browser.`
            : item.phase === "failed"
              ? (item.message ?? "The last sign-in failed.")
              : takesCode
                ? "The sign-in page opens in Safari; it ends with a code to paste back here."
                : "You'll get a short code to enter on the sign-in page.";

  return (
    <View className="gap-2 rounded-[22px] border border-warning-border bg-warning p-4">
      <Text className="text-sm font-t3-medium text-warning-foreground">{signInHeadline(item)}</Text>
      <Text className="text-xs text-warning-foreground">{helper}</Text>
      {item.provider === "aws" && item.account !== null ? (
        <View className="gap-1.5 rounded-xl bg-subtle px-3 py-2">
          {copyRow("Account", item.account.accountId)}
          {item.account.userName !== null ? copyRow("User", item.account.userName) : null}
        </View>
      ) : null}
      {item.userCode ? (
        <Text selectable className="text-lg font-t3-bold tabular-nums text-warning-foreground">
          {item.userCode}
        </Text>
      ) : null}
      <View className="flex-row flex-wrap items-center gap-2">
        {item.url !== null ? (
          <Pressable
            accessibilityRole="button"
            disabled={busy}
            onPress={() => openPage(item.url ?? "")}
            className="rounded-full bg-primary px-4 py-2 active:opacity-70"
          >
            <Text className="text-sm font-t3-bold text-primary-foreground">
              {busy && catchPort !== null ? "Waiting for the sign-in…" : "Open sign-in page"}
            </Text>
          </Pressable>
        ) : null}
        {item.phase === "idle" || item.phase === "failed" ? (
          <Pressable
            accessibilityRole="button"
            disabled={busy}
            onPress={() => void start(primaryMode)}
            className={cn(
              "rounded-full px-4 py-2 active:opacity-70",
              item.url ? "bg-subtle" : "bg-primary",
            )}
          >
            <Text
              className={cn(
                "text-sm font-t3-bold",
                item.url ? "text-foreground" : "text-primary-foreground",
              )}
            >
              {busy
                ? "Starting…"
                : item.phase === "failed"
                  ? "Try again"
                  : "Sign in from this phone"}
            </Text>
          </Pressable>
        ) : null}
        {running && takesCode && item.flow !== "remote" ? (
          <Pressable
            accessibilityRole="button"
            disabled={busy}
            onPress={() => void start("code")}
            className="rounded-full bg-subtle px-4 py-2 active:opacity-70"
          >
            <Text className="text-sm font-t3-bold text-foreground">Use a code instead</Text>
          </Pressable>
        ) : null}
      </View>
      {!running && takesCode && loopbackCatchSupported ? (
        <Pressable accessibilityRole="button" disabled={busy} onPress={() => void start("catch")}>
          <Text className="text-xs text-warning-foreground underline">
            Sign in here instead (no code, but no passkeys)
          </Text>
        </Pressable>
      ) : null}
      {pasteBack && !codeSent ? (
        <View className="gap-2">
          <TextInput
            value={code}
            onChangeText={setCode}
            multiline
            numberOfLines={3}
            placeholder="Authorization code"
            autoCapitalize="none"
            autoCorrect={false}
            autoComplete="off"
            spellCheck={false}
            textContentType="none"
            className="max-h-32 font-mono text-xs"
          />
          <View className="flex-row items-center gap-2">
            <Pressable
              accessibilityRole="button"
              disabled={busy}
              onPress={() => void pasteCode()}
              className="rounded-full bg-subtle px-4 py-2 active:opacity-70"
            >
              <Text className="text-sm font-t3-bold text-foreground">Paste</Text>
            </Pressable>
            <Pressable
              accessibilityRole="button"
              disabled={busy || code.trim() === ""}
              onPress={() => void sendCode()}
              className={cn(
                "rounded-full bg-primary px-4 py-2 active:opacity-70",
                code.trim() === "" && "opacity-50",
              )}
            >
              <Text className="text-sm font-t3-bold text-primary-foreground">
                {busy ? "Sending…" : "Send code"}
              </Text>
            </Pressable>
          </View>
        </View>
      ) : null}
      {error ? <Text className="text-xs text-danger-foreground">{error}</Text> : null}
    </View>
  );
}
