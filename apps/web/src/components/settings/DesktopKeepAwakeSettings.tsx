import { useClientSettings, useUpdateClientSettings } from "../../hooks/useSettings";
import { Switch } from "../ui/switch";
import { searchableSetting } from "./settingsSearch";
import { SettingsRow } from "./settingsLayout";

/**
 * Fork (#1075): the keep-awake switch on Settings › General, after the quit
 * row. Rendered only where the shell can hold a power-save blocker.
 */
export function DesktopKeepAwakeSettings() {
  const enabled = useClientSettings((settings) => settings.desktopKeepAwake);
  const updateSettings = useUpdateClientSettings();
  if (window.desktopBridge?.setKeepAwake === undefined) return null;
  const { id, title } = searchableSetting("desktop-keep-awake");
  return (
    <SettingsRow
      id={id}
      title={title}
      description="Sleep is held off while a thread on this computer has a turn running."
      control={
        <Switch
          checked={enabled}
          aria-label={title}
          onCheckedChange={(checked) => void updateSettings({ desktopKeepAwake: checked })}
        />
      }
    />
  );
}
