import { ProviderInteractionMode, RuntimeMode } from "@infinitus/contracts";
import { memo, type ReactNode, useRef } from "react";
import { EllipsisIcon } from "lucide-react";
import {
  Menu,
  MenuItem,
  MenuPopup,
  MenuRadioGroup,
  MenuRadioItem,
  MenuSeparator as MenuDivider,
  MenuTrigger,
} from "../ui/menu";
import { ComposerControl, ComposerControlIcon } from "./ComposerControl";
import { focusRequestedPermission, useComposerMenuProps } from "./composerEventScope";
import { useComposerMenuState } from "./useComposerMenuState";
import { ComposerPermissionsSection, type RuntimeModeOption } from "./ComposerFooterControls";

export const CompactComposerControlsMenu = memo(function CompactComposerControlsMenu(props: {
  interactionMode: ProviderInteractionMode;
  runtimeMode: RuntimeMode;
  runtimeModeOptions: ReadonlyArray<RuntimeModeOption>;
  showInteractionModeToggle: boolean;
  traitsMenuContent?: ReactNode;
  showPermissions?: boolean;
  size?: "sm" | "xs";
  /** Close the portaled popup when its trigger hides. */
  hidden?: boolean;
  onToggleInteractionMode: () => void;
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
            data-composer-shortcut={
              [
                props.showPermissions !== false ? "composer.mode" : null,
                props.traitsMenuContent ? "composer.effort" : null,
              ]
                .filter(Boolean)
                .join(" ") || undefined
            }
          />
        }
      >
        <ComposerControlIcon icon={EllipsisIcon} size={size} />
      </MenuTrigger>
      <MenuPopup align="start" {...composerFloatingLayerProps}>
        {props.traitsMenuContent ? (
          <>
            {props.traitsMenuContent}
            {props.showInteractionModeToggle || props.showPermissions !== false ? (
              <MenuDivider />
            ) : null}
          </>
        ) : null}
        {props.showInteractionModeToggle ? (
          <>
            <div className="px-2 py-1.5 font-medium text-muted-foreground text-xs">Mode</div>
            <MenuRadioGroup
              value={props.interactionMode}
              onValueChange={(value) => {
                if (!value || value === props.interactionMode) return;
                props.onToggleInteractionMode();
              }}
            >
              <MenuRadioItem value="default">Chat</MenuRadioItem>
              <MenuRadioItem value="plan">Plan</MenuRadioItem>
            </MenuRadioGroup>
            {props.showPermissions !== false ? <MenuDivider /> : null}
          </>
        ) : null}
<<<<<<< HEAD
        <div className="px-2 py-1.5 font-medium text-muted-foreground text-xs">Access</div>
        <MenuRadioGroup
          value={props.runtimeMode}
          onValueChange={(value) => {
            if (!value || value === props.runtimeMode) return;
            props.onRuntimeModeChange(value as RuntimeMode);
          }}
        >
          {props.runtimeModeOptions.map((option) => (
            <MenuRadioItem key={option.mode} value={option.mode}>
              {option.label}
            </MenuRadioItem>
          ))}
        </MenuRadioGroup>
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
        ) : null}
=======
        {props.showPermissions === false ? null : (
          <ComposerPermissionsSection
            runtimeMode={props.runtimeMode}
            runtimeModeOptions={props.runtimeModeOptions}
            onRuntimeModeChange={props.onRuntimeModeChange}
          />
        )}
>>>>>>> upstream-sync-32ecd7172-upstream-renamed
      </MenuPopup>
    </Menu>
  );
});
