import { useState } from "react";

import { usePrimarySettings, useUpdatePrimarySettings } from "../../../hooks/useSettings";
import { Button } from "../../ui/button";
import { Input } from "../../ui/input";
import { Switch } from "../../ui/switch";
import { SettingsRow, SettingsSection } from "../settingsLayout";
import {
  parseAllowedUserIds,
  slackStatusLine,
  slackTokenPatch,
  slackTokenSet,
  type SlackTokenField,
} from "./slack.logic";

const LABEL = "Start threads from Slack";

/**
 * Settings › Infinitus › Slack (#574): the server-side bridge's switch, the
 * two tokens (typed once, stored by the server, shown only as set / not
 * set) and the members allowed to use it. Server-scoped: the server that
 * holds the tokens is the one that connects.
 */
export function InfinitusSlackCard() {
  const slack = usePrimarySettings((settings) => settings.infinitusSlack);
  const updateSettings = useUpdatePrimarySettings();
  const [members, setMembers] = useState<string | null>(null);
  const membersDraft = members ?? slack.allowedUserIds.join(", ");
  return (
    <SettingsSection id="infinitus-slack" title="Slack">
      <SettingsRow
        serverScoped
        title={LABEL}
        description={`Mention the Infinitus app with a project and a task to start a thread that asks before edits; put "build" after the project to let it edit without asking. ${slackStatusLine(slack)}`}
        control={
          <Switch
            checked={slack.enabled}
            onCheckedChange={(checked) =>
              updateSettings({ infinitusSlack: { enabled: Boolean(checked) } })
            }
            aria-label={LABEL}
          />
        }
      />
      <TokenRow
        field="appToken"
        title="App-level token"
        description="From the Slack app's Basic Information page, with connections:write, for Socket Mode."
        set={slackTokenSet(slack.appToken)}
        onSave={(value) => updateSettings({ infinitusSlack: { appToken: value } })}
      />
      <TokenRow
        field="botToken"
        title="Bot token"
        description="From the app's OAuth page, for posting replies."
        set={slackTokenSet(slack.botToken)}
        onSave={(value) => updateSettings({ infinitusSlack: { botToken: value } })}
      />
      <SettingsRow
        serverScoped
        title="Allowed members"
        description="Slack member IDs, separated by commas. Nobody else gets a reply."
        control={
          <div className="flex items-center gap-2">
            <Input
              size="sm"
              aria-label="Allowed Slack member IDs"
              value={membersDraft}
              onChange={(event) => setMembers(event.target.value)}
              onBlur={() => {
                if (members === null) return;
                updateSettings({
                  infinitusSlack: { allowedUserIds: parseAllowedUserIds(members) },
                });
                setMembers(null);
              }}
            />
          </div>
        }
      />
    </SettingsSection>
  );
}

function TokenRow(props: {
  readonly field: SlackTokenField;
  readonly title: string;
  readonly description: string;
  readonly set: boolean;
  readonly onSave: (value: string) => void;
}) {
  const [draft, setDraft] = useState("");
  const save = () => {
    const value = slackTokenPatch(draft);
    if (value === null) return;
    props.onSave(value);
    setDraft("");
  };
  return (
    <SettingsRow
      serverScoped
      title={props.title}
      description={`${props.description} ${props.set ? "Set." : "Not set."}`}
      control={
        <div className="flex items-center gap-2">
          <Input
            size="sm"
            type="password"
            autoComplete="off"
            aria-label={props.title}
            placeholder={props.set ? "Replace" : "Paste"}
            value={draft}
            onChange={(event) => setDraft(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter") save();
            }}
          />
          <Button size="sm" variant="outline" onClick={save} disabled={draft.trim().length === 0}>
            Save
          </Button>
          {props.set ? (
            <Button size="sm" variant="ghost" onClick={() => props.onSave("")}>
              Clear
            </Button>
          ) : null}
        </div>
      }
    />
  );
}
