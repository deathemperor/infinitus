import { DEFAULT_UNIFIED_SETTINGS } from "@infinitus/contracts/settings";

import {
  NumberField,
  NumberFieldDecrement,
  NumberFieldGroup,
  NumberFieldIncrement,
  NumberFieldInput,
} from "../../ui/number-field";
import { SettingResetButton, SettingsRow } from "../settingsLayout";
import { normalizeIntervalSeconds } from "../SettingsPanels.logic";
import { searchableSetting } from "../settingsSearch";
import { useScopedSettings, useUpdateScopedSettings } from "../useScopedSettings";

/** Fork (#269 H): the worktree limit, a server setting, mounted by Settings › Worktrees. */
export function WorktreeLimitSetting() {
  const settings = useScopedSettings();
  const updateSettings = useUpdateScopedSettings();
  return (
    <SettingsRow
      serverScoped
      settingKeys={["worktreeMaxCount"]}
      {...searchableSetting("worktree-limit")}
      description="How many threads may hold a worktree at once. Past it a new worktree is refused until an archived thread is deleted; 0 lifts the limit."
      resetAction={
        settings.worktreeMaxCount !== DEFAULT_UNIFIED_SETTINGS.worktreeMaxCount ? (
          <SettingResetButton
            label="worktree limit"
            onClick={() =>
              updateSettings({ worktreeMaxCount: DEFAULT_UNIFIED_SETTINGS.worktreeMaxCount })
            }
          />
        ) : null
      }
      control={
        <NumberField
          value={settings.worktreeMaxCount}
          min={0}
          step={1}
          size="sm"
          className="w-28"
          onValueChange={(value) =>
            updateSettings({ worktreeMaxCount: normalizeIntervalSeconds(value) })
          }
        >
          <NumberFieldGroup>
            <NumberFieldDecrement aria-label="Decrease worktree limit" />
            <NumberFieldInput aria-label="Worktree limit" />
            <NumberFieldIncrement aria-label="Increase worktree limit" />
          </NumberFieldGroup>
        </NumberField>
      }
    />
  );
}
