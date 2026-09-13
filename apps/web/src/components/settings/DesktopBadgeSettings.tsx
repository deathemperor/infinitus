import { useClientSettings, useUpdateClientSettings } from "../../hooks/useSettings";
import { Switch } from "../ui/switch";
import { searchableSetting } from "./settingsSearch";
import { SettingsRow, SettingsSection } from "./settingsLayout";

/**
 * Fork (#270 B): the Dock badge switch, drawn above the menu-bar app's push
 * toggles. Banners and sounds are Settings › General › Thread notifications
 * (#1032). Rendered only where the shell has a Dock icon to badge.
 */
export function DesktopBadgeSettings() {
  const enabled = useClientSettings((settings) => settings.desktopBadgeAttention);
  const updateSettings = useUpdateClientSettings();
  if (window.desktopBridge?.setBadgeCount === undefined) return null;
  const { id, title } = searchableSetting("desktop-badge");
  return (
    <SettingsSection id="desktop-notifications" title="Desktop">
      <SettingsRow
        id={id}
        title={title}
        description="The Dock icon counts the threads waiting for an approval or an answer."
        control={
          <Switch
            checked={enabled}
            aria-label={title}
            onCheckedChange={(checked) => void updateSettings({ desktopBadgeAttention: checked })}
          />
        }
      />
    </SettingsSection>
  );
}
