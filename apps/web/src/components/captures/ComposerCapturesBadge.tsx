import { ListTodoIcon } from "lucide-react";
import { memo } from "react";

import { cn } from "~/lib/utils";
import { ComposerBanner } from "../chat/ComposerBanner";

/**
 * Shoulder tab beside the stash badge that opens the Captures popover (#433)
 * and shows how many captures are still open. Always drawn while the
 * composer has a project, so the feature is found without its shortcut.
 */
export const ComposerCapturesBadge = memo(function ComposerCapturesBadge(props: {
  openCount: number;
  menuOpen: boolean;
  onToggleMenu: () => void;
}) {
  return (
    <ComposerBanner.Root density="comfortable" width="content" data-composer-shoulder-tab>
      <ComposerBanner.Row
        render={<button type="button" />}
        data-captures-badge="true"
        aria-label={`Captures: ${props.openCount} open. ${props.menuOpen ? "Close" : "Open"} captures.`}
        aria-expanded={props.menuOpen}
        className={cn(
          "transition-colors duration-200",
          props.menuOpen ? "text-foreground" : "text-muted-foreground hover:text-foreground",
        )}
        onPointerDown={(event) => event.preventDefault()}
        onClick={props.onToggleMenu}
      >
        <ComposerBanner.Icon>
          <ListTodoIcon />
        </ComposerBanner.Icon>
        <ComposerBanner.Content>Captures</ComposerBanner.Content>
        {props.openCount > 0 ? (
          <ComposerBanner.Actions>
            <ComposerBanner.Count className="text-muted-foreground">
              {props.openCount}
            </ComposerBanner.Count>
          </ComposerBanner.Actions>
        ) : null}
      </ComposerBanner.Row>
    </ComposerBanner.Root>
  );
});
