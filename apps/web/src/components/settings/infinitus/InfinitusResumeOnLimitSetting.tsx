import { ScopedSwitch } from "../ScopedSwitch";
import { SettingsRow } from "../settingsLayout";
import { searchableSetting } from "../settingsSearch";
import { useScopedSettings, useUpdateScopedSettings } from "../useScopedSettings";

/**
 * Fork (#648): the swap-based resume, rendered by Settings › General beside
 * upstream's reset-time one. A server setting, so the row is scoped like its
 * neighbours.
 */
export function InfinitusResumeOnLimitSetting() {
  const enabled = useScopedSettings((settings) => settings.infinitusResumeOnLimit);
  const updateSettings = useUpdateScopedSettings();
  return (
    <SettingsRow
      serverScoped
      {...searchableSetting("infinitus-resume-on-limit")}
      description="When the Claude account behind a running thread hits its usage limit and Infinitus swaps, the turn continues on the new account before the window resets."
      settingKeys={["infinitusResumeOnLimit"]}
      control={
        <ScopedSwitch
          settingKeys={["infinitusResumeOnLimit"]}
          checked={enabled}
          onCheckedChange={(checked) =>
            updateSettings({ infinitusResumeOnLimit: Boolean(checked) })
          }
          aria-label="Resume limited threads on another account"
        />
      }
    />
  );
}
