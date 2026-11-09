import type { RuntimeMode } from "@infinitus/contracts";
import { memo, useRef } from "react";
import { EllipsisIcon } from "lucide-react";
<<<<<<< HEAD
import {
  Menu,
  MenuItem,
  MenuPopup,
  MenuRadioGroup,
  MenuRadioItem,
  MenuSeparator as MenuDivider,
  MenuTrigger,
} from "../ui/menu";
=======
import { Menu, MenuPopup, MenuTrigger } from "../ui/menu";
>>>>>>> upstream-sync-4f0b74e190-upstream-renamed
import { ComposerControl, ComposerControlIcon } from "./ComposerControl";
import { focusRequestedPermission, useComposerMenuProps } from "./composerEventScope";
import { useComposerMenuState } from "./useComposerMenuState";
import { ComposerPermissionsSection, type RuntimeModeOption } from "./ComposerFooterControls";

export const CompactComposerControlsMenu = memo(function CompactComposerControlsMenu(props: {
  runtimeMode: RuntimeMode;
  runtimeModeOptions: ReadonlyArray<RuntimeModeOption>;
  showPermissions: boolean;
  size?: "sm" | "xs";
  /** Close the portaled popup when its trigger hides. */
  hidden?: boolean;
  onRuntimeModeChange: (mode: RuntimeMode) => void;
  /** Fork (#269 C): opens a read-only side question in the right panel. */
  onAskSideQuestion?: (() => void) | undefined;
  /** Fork (#269 C): set, the item is off. */
  sideQuestionUnavailable?: string | undefined;
}) {
  const composerFloatingLayerProps = useComposerMenuProps();
  const size = props.size ?? "sm";
  const [open, setOpen] = useComposerMenuState(props.hidden);
  const triggerRef = useRef<HTMLButtonElement>(null);

  return (
    <Menu
      open={open}
      onOpenChange={setOpen}
      onOpenChangeComplete={(isOpen) => focusRequestedPermission(isOpen, triggerRef.current)}
    >
      <MenuTrigger
        render={
          <ComposerControl
            ref={triggerRef}
            size={size}
            className="shrink-0"
            aria-label="More composer controls"
            data-composer-shortcut={props.showPermissions ? "composer.mode" : undefined}
          />
        }
      >
        <ComposerControlIcon icon={EllipsisIcon} size={size} />
      </MenuTrigger>
      <MenuPopup align="start" {...composerFloatingLayerProps}>
        {props.showPermissions ? (
          <ComposerPermissionsSection
            runtimeMode={props.runtimeMode}
            runtimeModeOptions={props.runtimeModeOptions}
            onRuntimeModeChange={props.onRuntimeModeChange}
          />
<<<<<<< HEAD
        )}
        {props.onAskSideQuestion ? (
          <>
            <MenuDivider />
            <MenuItem
              onClick={props.onAskSideQuestion}
              disabled={props.sideQuestionUnavailable !== undefined}
            >
              Ask a side question
            </MenuItem>
          </>
=======
>>>>>>> upstream-sync-4f0b74e190-upstream-renamed
        ) : null}
      </MenuPopup>
    </Menu>
  );
});
