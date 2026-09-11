import { BookmarkIcon } from "lucide-react";
import { memo } from "react";

import { cn } from "~/lib/utils";
import { ComposerBanner } from "../chat/ComposerBanner";

/**
 * Shoulder tab beside the Captures badge that opens the Prompts popover
 * (#270 G) and shows how many snippets the project has saved.
 */
export const ComposerPromptsBadge = memo(function ComposerPromptsBadge(props: {
  count: number;
  menuOpen: boolean;
  onToggleMenu: () => void;
}) {
  return (
    <ComposerBanner.Root density="comfortable" width="content" data-composer-shoulder-tab>
      <ComposerBanner.Row
        render={<button type="button" />}
        data-prompts-badge="true"
        aria-label={`Prompts: ${props.count} saved. ${props.menuOpen ? "Close" : "Open"} prompts.`}
        aria-expanded={props.menuOpen}
        className={cn(
          "transition-colors duration-200",
          props.menuOpen ? "text-foreground" : "text-muted-foreground hover:text-foreground",
        )}
        onPointerDown={(event) => event.preventDefault()}
        onClick={props.onToggleMenu}
      >
        <ComposerBanner.Icon>
          <BookmarkIcon />
        </ComposerBanner.Icon>
        <ComposerBanner.Content>Prompts</ComposerBanner.Content>
        {props.count > 0 ? (
          <ComposerBanner.Actions>
            <ComposerBanner.Count className="text-muted-foreground">
              {props.count}
            </ComposerBanner.Count>
          </ComposerBanner.Actions>
        ) : null}
      </ComposerBanner.Row>
    </ComposerBanner.Root>
  );
});
