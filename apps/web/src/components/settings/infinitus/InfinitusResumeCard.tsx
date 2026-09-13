import { DEFAULT_UNIFIED_SETTINGS } from "@t3tools/contracts";

import { usePrimarySettings, useUpdatePrimarySettings } from "../../../hooks/useSettings";
import { Switch } from "../../ui/switch";
import { SettingResetButton, SettingsRow, SettingsSection } from "../settingsLayout";

const LABEL = "Resume a thread after a usage limit";

/**
 * The server's resume-on-limit switch (#648): a thread's turn stopped by a
 * Claude usage limit continues on the account Infinitus swapped to, with a
 * marker row in the thread. Server-scoped: the server that runs the thread is
 * the one that resumes it.
 */
export function InfinitusResumeCard() {
  const enabled = usePrimarySettings((settings) => settings.infinitusResumeOnLimit);
  const updateSettings = useUpdatePrimarySettings();
  return (
    <SettingsSection id="infinitus-resume" title="Threads">
      <SettingsRow
        serverScoped
        title={LABEL}
        description="When the account behind a running thread hits its usage limit and Infinitus swaps, the turn continues on the new account. The thread shows where it resumed."
        resetAction={
          enabled !== DEFAULT_UNIFIED_SETTINGS.infinitusResumeOnLimit ? (
            <SettingResetButton
              label="resume after a usage limit"
              onClick={() =>
                updateSettings({
                  infinitusResumeOnLimit: DEFAULT_UNIFIED_SETTINGS.infinitusResumeOnLimit,
                })
              }
            />
          ) : null
        }
        control={
          <Switch
            checked={enabled}
            onCheckedChange={(checked) =>
              updateSettings({ infinitusResumeOnLimit: Boolean(checked) })
            }
            aria-label={LABEL}
          />
        }
      />
    </SettingsSection>
  );
}
