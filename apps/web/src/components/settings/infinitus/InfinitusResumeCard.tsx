import { DEFAULT_UNIFIED_SETTINGS } from "@t3tools/contracts";

import { usePrimarySettings, useUpdatePrimarySettings } from "../../../hooks/useSettings";
import { Switch } from "../../ui/switch";
import { SettingResetButton, SettingsRow, SettingsSection } from "../settingsLayout";

const LABEL = "Resume a thread after a usage limit";
const PUSH_LABEL = "Push thread alerts through Infinitus";

/**
 * The server's resume-on-limit switch (#648): a thread's turn stopped by a
 * Claude usage limit continues on the account Infinitus swapped to, with a
 * marker row in the thread. Server-scoped: the server that runs the thread is
 * the one that resumes it. Below it the push bridge switch (#269 G): a
 * thread waiting on a person, finished or failed goes out through the Mac's
 * channels — the phone, Slack, Telegram; the Mac skips its own notice since
 * the desktop's notifications already cover this screen.
 */
export function InfinitusResumeCard() {
  const enabled = usePrimarySettings((settings) => settings.infinitusResumeOnLimit);
  const pushEnabled = usePrimarySettings((settings) => settings.infinitusPushBridge);
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
      <SettingsRow
        serverScoped
        title={PUSH_LABEL}
        description="When a thread waits for an approval or an answer, finishes or fails, Infinitus sends the alert the way it sends its own: the phone, Slack, Telegram. On this Mac the desktop's own notification is the only one."
        resetAction={
          pushEnabled !== DEFAULT_UNIFIED_SETTINGS.infinitusPushBridge ? (
            <SettingResetButton
              label="push thread alerts"
              onClick={() =>
                updateSettings({
                  infinitusPushBridge: DEFAULT_UNIFIED_SETTINGS.infinitusPushBridge,
                })
              }
            />
          ) : null
        }
        control={
          <Switch
            checked={pushEnabled}
            onCheckedChange={(checked) => updateSettings({ infinitusPushBridge: Boolean(checked) })}
            aria-label={PUSH_LABEL}
          />
        }
      />
    </SettingsSection>
  );
}
