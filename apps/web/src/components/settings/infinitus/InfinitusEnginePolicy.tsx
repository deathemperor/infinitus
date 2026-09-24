/**
 * Settings › Engines › Switching policy: one section per fleet whose engine
 * has policy knobs (swapd `config`), each knob a row drawn from the engine's
 * own list — its help line, its default, and a control its value's type calls
 * for. A write is one `policy-set` / `policy-unset` over `infinitus.command`
 * on the environment this page manages, so another machine's knobs are set
 * from here too; the engine's refusal (a value off the knob's range) is shown
 * in its own words, and the list is re-read after every write.
 *
 * @module InfinitusEnginePolicy
 */
import { useCallback, useEffect, useState } from "react";

import type { EnvironmentPresentation } from "~/state/environments";
import { infinitusEnvironment } from "~/state/infinitus";
import { useAtomCommand } from "~/state/use-atom-command";

import { Button } from "../../ui/button";
import { Input } from "../../ui/input";
import { Select, SelectItem, SelectPopup, SelectTrigger, SelectValue } from "../../ui/select";
import { Switch } from "../../ui/switch";
import { SettingsRow, SettingsSection } from "../settingsLayout";
import { useInfinitusEnvironment } from "./InfinitusPrefsPanel";
import { infinitusCommandFailure } from "./panel.logic";
import {
  parsePolicy,
  policyFleets,
  policyReadInput,
  policyRows,
  policySetInput,
  policySupported,
  policyUnsetInput,
  policyWireValue,
  type PolicyRow,
} from "./policy.logic";

interface FleetPolicy {
  readonly rows: ReadonlyArray<PolicyRow>;
  readonly error: string | null;
  readonly busy: boolean;
}

export function InfinitusEnginePolicy({
  environment,
}: {
  readonly environment?: EnvironmentPresentation | null;
}) {
  const { environmentId, snapshot } = useInfinitusEnvironment(environment);
  const runCommand = useAtomCommand(infinitusEnvironment.command, { reportFailure: false });
  const [policies, setPolicies] = useState<Readonly<Record<string, FleetPolicy>>>({});

  const supported = snapshot !== null && snapshot.available && policySupported(snapshot.commands);
  const fleetKeys = supported ? policyFleets(snapshot.fleets).map((fleet) => fleet.key) : [];
  // A string, so the effect below re-runs when the set of fleets changes and
  // not on every snapshot poll.
  const fleetList = fleetKeys.join("\n");

  const patch = useCallback((fleet: string, change: Partial<FleetPolicy>) => {
    setPolicies((current) => ({
      ...current,
      [fleet]: { rows: [], error: null, busy: false, ...current[fleet], ...change },
    }));
  }, []);

  const read = useCallback(
    async (fleet: string) => {
      if (environmentId === null) return;
      const result = await runCommand({ environmentId, input: policyReadInput(fleet) });
      if (result._tag === "Failure") {
        patch(fleet, { error: infinitusCommandFailure(result.cause).message, busy: false });
        return;
      }
      const parsed = parsePolicy(result.value.result);
      if (parsed === null) {
        patch(fleet, {
          error: "Infinitus answered policy with a shape this build cannot read.",
          busy: false,
        });
        return;
      }
      patch(fleet, { rows: policyRows(parsed.settings), error: null, busy: false });
    },
    [environmentId, patch, runCommand],
  );

  const write = useCallback(
    async (fleet: string, row: PolicyRow, value: string | null) => {
      if (environmentId === null) return;
      patch(fleet, { busy: true });
      const input =
        value === null ? policyUnsetInput(fleet, row.key) : policySetInput(fleet, row.key, value);
      const result = await runCommand({ environmentId, input });
      if (result._tag === "Failure") {
        patch(fleet, { error: infinitusCommandFailure(result.cause).message, busy: false });
        return;
      }
      await read(fleet);
    },
    [environmentId, patch, read, runCommand],
  );

  useEffect(() => {
    if (fleetList === "") return;
    // oxlint-disable-next-line react/set-state-in-effect -- The engine is read over the socket once the fleets are known; every set lands after its reply.
    for (const fleet of fleetList.split("\n")) void read(fleet);
  }, [fleetList, read]);

  if (fleetKeys.length === 0) return null;

  return (
    <>
      {fleetKeys.map((fleet) => {
        const policy = policies[fleet];
        return (
          <SettingsSection
            key={fleet}
            id={`infinitus-policy-${fleet.replaceAll("/", "-")}`}
            title={`Switching policy · ${fleet}`}
          >
            {policy === undefined || (policy.rows.length === 0 && policy.error === null) ? (
              <p role="status" className="px-3 py-3 text-[13px] text-muted-foreground sm:px-4">
                Reading the engine's settings…
              </p>
            ) : null}
            {policy?.rows.map((row) => (
              <PolicyRowView
                key={row.key}
                fleet={fleet}
                row={row}
                locked={policy.busy}
                onSet={(value) => void write(fleet, row, value)}
                onUnset={() => void write(fleet, row, null)}
              />
            ))}
            {policy?.error === null || policy?.error === undefined ? null : (
              <p role="alert" className="px-3 py-2 text-[13px] text-destructive sm:px-4">
                {policy.error}
              </p>
            )}
          </SettingsSection>
        );
      })}
    </>
  );
}

/** One knob. A typed field commits on Enter or when focus leaves it, and only
    when the text changed, so a glance never writes; "Reset" drops the knob so
    the engine's default applies again. */
function PolicyRowView({
  fleet,
  row,
  locked,
  onSet,
  onUnset,
}: {
  readonly fleet: string;
  readonly row: PolicyRow;
  readonly locked: boolean;
  readonly onSet: (value: string) => void;
  readonly onUnset: () => void;
}) {
  const [draft, setDraft] = useState<string | null>(null);
  const text = draft ?? row.value;
  const commit = () => {
    if (draft === null) return;
    const wire = policyWireValue(row, draft);
    setDraft(null);
    if (wire !== policyWireValue(row, row.value)) onSet(wire);
  };
  const label = `${fleet} ${row.label}`;
  const reset = row.isSet ? (
    <Button size="sm" variant="ghost" aria-label={`Reset ${label}`} disabled={locked} onClick={onUnset}>
      Reset
    </Button>
  ) : null;

  let control: React.ReactNode;
  switch (row.control.kind) {
    case "switch":
      control = (
        <Switch
          disabled={locked}
          checked={row.on}
          aria-label={label}
          onCheckedChange={(checked) => onSet(checked === true ? "true" : "false")}
        />
      );
      break;
    case "select": {
      const choices = row.control.choices;
      control = (
        <Select
          disabled={locked}
          value={row.value}
          onValueChange={(value) => {
            if (value !== null && value !== row.value) onSet(value);
          }}
        >
          <SelectTrigger size="sm" className="w-full sm:w-48" aria-label={label}>
            <SelectValue>{row.value}</SelectValue>
          </SelectTrigger>
          <SelectPopup align="end" alignItemWithTrigger={false}>
            {(choices.includes(row.value) ? choices : [...choices, row.value]).map((choice) => (
              <SelectItem hideIndicator key={choice} value={choice}>
                {choice}
              </SelectItem>
            ))}
          </SelectPopup>
        </Select>
      );
      break;
    }
    default:
      control = (
        <Input
          size="sm"
          font={row.control.kind === "number" ? "mono" : "default"}
          inputMode={row.control.kind === "number" ? "decimal" : "text"}
          className="w-full sm:w-48"
          aria-label={label}
          disabled={locked}
          value={text}
          onChange={(event) => setDraft(event.target.value)}
          onBlur={commit}
          onKeyDown={(event) => {
            if (event.key === "Enter") {
              event.preventDefault();
              commit();
            } else if (event.key === "Escape") {
              setDraft(null);
            }
          }}
        />
      );
  }

  return (
    <SettingsRow
      serverScoped
      title={row.label}
      description={`${row.help}. Default: ${row.defaultText === "" ? "none" : row.defaultText}.`}
      control={
        <span className="flex items-center gap-1.5">
          {control}
          {reset}
        </span>
      }
    />
  );
}
