import type { InfinitusDesktopPrefs } from "@t3tools/contracts/infinitus";
import { useEffect, useMemo, useState } from "react";

import { Switch } from "../../ui/switch";
import { SettingsRow, SettingsSection } from "../settingsLayout";

type InfinitusDesktopBridge = {
  readonly getInfinitusDesktopPrefs: () => Promise<InfinitusDesktopPrefs>;
  readonly setInfinitusQuitWithApp: (enabled: boolean) => Promise<InfinitusDesktopPrefs>;
  /** Absent under a shell before the capture gesture, or off a Mac: the row hides. */
  readonly setInfinitusCaptureGestureEnabled?: (enabled: boolean) => Promise<InfinitusDesktopPrefs>;
};

/** The bridge, when this is the desktop shell and it is new enough to carry
    the fork's Infinitus prefs; anything else hides the card. */
export function infinitusDesktopBridge(
  bridge:
    | (Partial<InfinitusDesktopBridge> & { readonly getClientPlatform?: () => string })
    | undefined,
): InfinitusDesktopBridge | null {
  if (bridge?.getInfinitusDesktopPrefs === undefined) return null;
  if (bridge.setInfinitusQuitWithApp === undefined) return null;
  const onMac = bridge.getClientPlatform?.() === "darwin";
  return {
    getInfinitusDesktopPrefs: bridge.getInfinitusDesktopPrefs,
    setInfinitusQuitWithApp: bridge.setInfinitusQuitWithApp,
    ...(onMac && bridge.setInfinitusCaptureGestureEnabled !== undefined
      ? { setInfinitusCaptureGestureEnabled: bridge.setInfinitusCaptureGestureEnabled }
      : {}),
  };
}

/**
 * The desktop shell's own Infinitus knobs (#654 step 1), on the Infinitus
 * settings index. These describe this window, so they come from the shell over
 * the bridge rather than from the app's pref catalog.
 */
export function InfinitusDesktopCard() {
  // The bridge is a window global fixed for the page's life; memoised so the
  // read effect runs once, not per render.
  const bridge = useMemo(
    () => infinitusDesktopBridge(typeof window === "undefined" ? undefined : window.desktopBridge),
    [],
  );
  const [prefs, setPrefs] = useState<InfinitusDesktopPrefs | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (bridge === null) return;
    let cancelled = false;
    bridge.getInfinitusDesktopPrefs().then(
      (loaded) => {
        if (!cancelled) setPrefs(loaded);
      },
      (cause: unknown) => {
        if (!cancelled) setError(cause instanceof Error ? cause.message : String(cause));
      },
    );
    return () => {
      cancelled = true;
    };
  }, [bridge]);

  if (bridge === null) return null;

  const write = (change: Promise<InfinitusDesktopPrefs>) => {
    setError(null);
    change.then(setPrefs, (cause: unknown) => {
      setError(cause instanceof Error ? cause.message : String(cause));
    });
  };
  const setCaptureGesture = bridge.setInfinitusCaptureGestureEnabled;

  return (
    <SettingsSection id="infinitus-desktop" title="This window">
      <SettingsRow
        title="Quit the menu-bar app with this window"
        description="Quitting this app also quits Infinitus. Off, the menu-bar app keeps running on its own."
        status={error === null ? undefined : <span className="text-destructive">{error}</span>}
        control={
          <Switch
            aria-label="Quit the menu-bar app with this window"
            disabled={prefs === null}
            checked={prefs?.quitInfinitusWithApp === true}
            onCheckedChange={(checked) => write(bridge.setInfinitusQuitWithApp(checked === true))}
          />
        }
      />
      {setCaptureGesture === undefined ? null : (
        <SettingsRow
          title="Capture selected text with a double tap of Shift"
          description="In any app, select text and tap Shift twice to add it to the active project's captures. Needs the Accessibility permission, asked for when this turns on."
          control={
            <Switch
              aria-label="Capture selected text with a double tap of Shift"
              disabled={prefs === null}
              checked={prefs?.captureGestureEnabled === true}
              onCheckedChange={(checked) => write(setCaptureGesture(checked === true))}
            />
          }
        />
      )}
    </SettingsSection>
  );
}
