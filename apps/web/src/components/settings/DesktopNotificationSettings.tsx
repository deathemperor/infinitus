import type { ClientSettingsPatch } from "@t3tools/contracts";

import { useClientSettings, useUpdateClientSettings } from "../../hooks/useSettings";
import { Switch } from "../ui/switch";
import { searchableSetting } from "./settingsSearch";
import { SettingsRow, SettingsSection } from "./settingsLayout";

type Toggle =
  | "desktopNotifyOnApproval"
  | "desktopNotifyOnInput"
  | "desktopNotifyOnHeld"
  | "desktopNotifyOnFailure"
  | "desktopNotifyOnCompletion"
  | "desktopBadgeAttention";

const ROWS: ReadonlyArray<{
  readonly key: Toggle;
  readonly search: Parameters<typeof searchableSetting>[0];
  readonly description: string;
}> = [
  {
    key: "desktopNotifyOnApproval",
    search: "desktop-notify-approval",
    description: "A thread is waiting for you to approve something.",
  },
  {
    key: "desktopNotifyOnInput",
    search: "desktop-notify-input",
    description: "A thread asked a question and is waiting for the answer.",
  },
  {
    key: "desktopNotifyOnHeld",
    search: "desktop-notify-held",
    description: "A turn was held for headroom instead of starting.",
  },
  {
    key: "desktopNotifyOnFailure",
    search: "desktop-notify-failure",
    description: "A thread's session failed.",
  },
  {
    key: "desktopNotifyOnCompletion",
    search: "desktop-notify-completion",
    description: "A turn finished. Off by default: every finish is a lot of banners.",
  },
  {
    key: "desktopBadgeAttention",
    search: "desktop-badge",
    description: "The Dock icon counts the threads waiting for an approval or an answer.",
  },
];

/**
 * Fork (#270 B): the desktop's own notifications, drawn above the menu-bar
 * app's push toggles. Client settings, so a second desktop sharing the
 * server follows the same choices. Rendered only where the shell can post.
 */
export function DesktopNotificationSettings() {
  const settings = useClientSettings();
  const updateSettings = useUpdateClientSettings();
  if (window.desktopBridge?.postNotification === undefined) return null;
  return (
    <SettingsSection id="desktop-notifications" title="Desktop notifications">
      {ROWS.map((row) => {
        const { id, title } = searchableSetting(row.search);
        return (
          <SettingsRow
            key={row.key}
            id={id}
            title={title}
            description={row.description}
            control={
              <Switch
                checked={settings[row.key]}
                aria-label={title}
                onCheckedChange={(checked) => {
                  const patch: ClientSettingsPatch = { [row.key]: checked };
                  void updateSettings(patch);
                }}
              />
            }
          />
        );
      })}
    </SettingsSection>
  );
}
