import { SCAN_IN_APP_NOTICE } from "../settings/infinitus/pairPhone.logic";
import { AuthSurfaceShell } from "./AuthSurfaceShell";

/**
 * What `/pair` shows for a link the Devices card minted for the phone
 * (`#token=…&for=phone`, #724): the QR was scanned with the Camera app and
 * landed in the phone's browser. Pairing this browser would spend the
 * one-time code and leave the app unpaired, so nothing is submitted; the
 * token stays in the fragment for the app to take from the same URL.
 */
export function InfinitusPhoneLinkSurface() {
  return (
    <AuthSurfaceShell>
      <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">
        This link is for the Infinitus phone app
      </h1>
      <p className="mt-3 text-sm leading-relaxed text-muted-foreground">{SCAN_IN_APP_NOTICE}</p>
      <p className="mt-3 text-sm leading-relaxed text-muted-foreground">
        Nothing was paired here, so the code is still good. To pair a browser instead, use a pairing
        link from the Mac&apos;s Settings › Connections.
      </p>
    </AuthSurfaceShell>
  );
}
