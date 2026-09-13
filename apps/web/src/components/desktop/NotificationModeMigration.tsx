import { useEffect } from "react";

import {
  ensureClientSettingsHydrated,
  getClientSettings,
  persistClientSettingsPatch,
} from "../../hooks/useSettings";
import { legacyNotificationMode } from "../../lib/infinitusNotifications.logic";

const MARKER_KEY = "infinitus:notification-mode:migrated:v1";
const LEGACY_SOUND_KEY = "infinitus:completion-sound:v1";

function readLegacySoundEnabled(): boolean {
  try {
    const raw = window.localStorage.getItem(LEGACY_SOUND_KEY);
    if (raw === null) return false;
    const parsed: unknown = JSON.parse(raw);
    return (
      typeof parsed === "object" &&
      parsed !== null &&
      (parsed as { enabled?: unknown }).enabled === true
    );
  } catch {
    return false;
  }
}

/**
 * Fork (#1032): carries a client's #270 B desktop toggles and #270 H sound
 * over to upstream's `notificationMode` once, so nobody loses a banner or a
 * bell to the convergence. Runs once per install (a localStorage marker),
 * only while the mode still reads `off`; the old sound key is removed.
 */
export function NotificationModeMigration() {
  useEffect(() => {
    let cancelled = false;
    void (async () => {
      try {
        if (window.localStorage.getItem(MARKER_KEY) !== null) return;
      } catch {
        return;
      }
      try {
        await ensureClientSettingsHydrated();
      } catch {
        return;
      }
      if (cancelled) return;
      const settings = getClientSettings();
      const mode = legacyNotificationMode(
        window.desktopBridge === undefined ? null : settings,
        readLegacySoundEnabled(),
      );
      if (settings.notificationMode === "off" && mode !== "off") {
        await persistClientSettingsPatch({ notificationMode: mode });
      }
      try {
        window.localStorage.setItem(MARKER_KEY, "1");
        window.localStorage.removeItem(LEGACY_SOUND_KEY);
      } catch {
        // A blocked store runs the mapping again next launch; it is idempotent.
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);
  return null;
}
