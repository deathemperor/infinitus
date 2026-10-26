import { requireOptionalNativeModule } from "expo";
import { Platform } from "react-native";

interface InfinitusLoopbackCatchModule {
  /** Binds this phone's loopback on `port`; rejects when the port is taken. */
  listen(port: number): Promise<void>;
  /** The URL the browser asked for, verbatim, or null when `stop` came first. */
  awaitRedirect(): Promise<string | null>;
  /** Gives the port back and lets any waiter go. */
  stop(): Promise<void>;
}

/** The fork's `InfinitusLoopbackCatch` module: the phone answers the sign-in redirect the
    AWS and gcloud CLIs send to a loopback port. Null on Android and on an older iOS
    build, where the sign-in page opens in the system browser. */
const native: InfinitusLoopbackCatchModule | null =
  Platform.OS === "ios"
    ? requireOptionalNativeModule<InfinitusLoopbackCatchModule>("InfinitusLoopbackCatch")
    : null;

export const loopbackCatchSupported = native !== null;

/** Binds the port. Await it before the sign-in page is opened: a browser that
    reaches the redirect with nothing listening has nowhere to hand the code. */
export function listenForLoopbackRedirect(port: number): Promise<void> {
  return native === null ? Promise.reject(new Error("No loopback catcher.")) : native.listen(port);
}

export function awaitLoopbackRedirect(): Promise<string | null> {
  return native === null ? Promise.resolve(null) : native.awaitRedirect();
}

export function stopLoopbackCatch(): Promise<void> {
  return native === null ? Promise.resolve() : native.stop();
}
