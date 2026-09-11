import { ChevronDownIcon, PlayIcon } from "lucide-react";

import { cn } from "~/lib/utils";

import {
  playCompletionSound,
  setCompletionSoundPreference,
  useCompletionSoundPreference,
} from "../../lib/infinitusCompletionSound";
import {
  COMPLETION_SOUNDS,
  type CompletionSound,
  completionSoundLabel,
  DEFAULT_COMPLETION_SOUND,
  isCompletionSound,
} from "../../lib/infinitusCompletionSound.logic";
import { Menu, MenuItem, MenuPopup, MenuRadioGroup, MenuRadioItem, MenuTrigger } from "../ui/menu";
import { selectTriggerVariants } from "../ui/select";
import { SettingsRow } from "./settingsLayout";
import { searchableSetting } from "./settingsSearch";

const optionRowClassName = "flex items-center gap-1 pe-1";
const optionItemClassName = "data-checked:bg-transparent";
const previewClassName = "min-h-7 w-7 justify-center px-0";

/**
 * "Completion sound" (#270 H), beside the SnapShot capture sound: off, or one
 * of the bundled sounds, each with a play button so the pick is heard before
 * a turn finishes in the background. Per window, not a client setting.
 */
export function InfinitusCompletionSoundRow() {
  const preference = useCompletionSoundPreference();
  const selection: CompletionSound | "off" = preference.enabled ? preference.sound : "off";
  const label = selection === "off" ? "Off" : completionSoundLabel(selection);
  return (
    <SettingsRow
      {...searchableSetting("completion-sound")}
      description="Play a sound when a turn finishes while this window is in the background."
      control={
        <Menu>
          <MenuTrigger
            aria-label={"Completion sound: " + label}
            className={cn(selectTriggerVariants({ size: "sm" }), "w-auto min-w-0")}
          >
            <span className="min-w-0 flex-1 truncate text-left">
              {selection === DEFAULT_COMPLETION_SOUND ? (
                <>
                  {label} <span className="text-muted-foreground">(Default)</span>
                </>
              ) : (
                label
              )}
            </span>
            <ChevronDownIcon className="-me-1 size-3 shrink-0 opacity-50" />
          </MenuTrigger>
          <MenuPopup align="end">
            <MenuRadioGroup
              onValueChange={(value) =>
                setCompletionSoundPreference(
                  isCompletionSound(value) ? { enabled: true, sound: value } : { enabled: false },
                )
              }
              value={selection}
            >
              <MenuRadioItem closeOnClick value="off">
                Off
              </MenuRadioItem>
              {COMPLETION_SOUNDS.map((sound) => (
                <div className={optionRowClassName} key={sound}>
                  <MenuRadioItem className={optionItemClassName} closeOnClick value={sound}>
                    {completionSoundLabel(sound)}
                    {sound === DEFAULT_COMPLETION_SOUND ? (
                      <span className="text-muted-foreground"> (Default)</span>
                    ) : null}
                  </MenuRadioItem>
                  <MenuItem
                    aria-label={`Play ${completionSoundLabel(sound)}`}
                    className={previewClassName}
                    closeOnClick={false}
                    onClick={() => playCompletionSound(sound)}
                  >
                    <PlayIcon />
                  </MenuItem>
                </div>
              ))}
            </MenuRadioGroup>
          </MenuPopup>
        </Menu>
      }
    />
  );
}
