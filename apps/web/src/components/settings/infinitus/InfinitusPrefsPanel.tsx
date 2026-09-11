/**
 * The Infinitus preference panes. Every row is drawn from the native app's own
 * `prefs` catalog rather than from anything declared here, so a pref the app
 * adds shows up without a fork release; the pane only picks the control, sends
 * `prefs set <key> <json>` over the control socket, and says what came back.
 *
 * @module InfinitusPrefsPanel
 */
import type { EnvironmentId } from "@t3tools/contracts";
import type { InfinitusPref, InfinitusSnapshot } from "@t3tools/contracts/infinitus";
import { useCallback, useEffect, useMemo, useReducer, useState, type ReactNode } from "react";

import { usePrimaryEnvironment } from "~/state/environments";
import { infinitusEnvironment } from "~/state/infinitus";
import { useEnvironmentQuery } from "~/state/query";
import { useAtomCommand } from "~/state/use-atom-command";

import {
  AlertDialog,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogPopup,
  AlertDialogTitle,
} from "../../ui/alert-dialog";
import { Button } from "../../ui/button";
import { DraftInput } from "../../ui/draft-input";
import { NumberField, NumberFieldGroup, NumberFieldInput } from "../../ui/number-field";
import { Select, SelectItem, SelectPopup, SelectTrigger, SelectValue } from "../../ui/select";
import { Switch } from "../../ui/switch";
import {
  SettingResetButton,
  SettingsPageContainer,
  SettingsRow,
  SettingsSection,
} from "../settingsLayout";
import {
  infinitusCommandFailure,
  infinitusPanelMessage,
  infinitusPrefsPanelState,
  prefDefaultHint,
} from "./panel.logic";
import { InfinitusLaunchButton } from "./InfinitusLaunchButton";
import {
  buildPrefSections,
  defaultValue,
  displayValue,
  initialPrefWriteState,
  parseControlInput,
  prefWriteArgs,
  reducePrefWrite,
  type PrefRowModel,
} from "./prefsForm.logic";

/** The primary environment's Infinitus view: the capability that says whether
    to draw anything at all, and the latest whole snapshot. */
export function useInfinitusEnvironment(): {
  readonly environmentId: EnvironmentId | null;
  readonly capability: boolean | undefined;
  readonly snapshot: InfinitusSnapshot | null;
} {
  const environment = usePrimaryEnvironment();
  const environmentId = environment?.environmentId ?? null;
  const capability = environment?.serverConfig?.environment.capabilities.infinitus;
  const query = useEnvironmentQuery(
    environmentId === null ? null : infinitusEnvironment.snapshot({ environmentId, input: {} }),
  );
  return { environmentId, capability, snapshot: query.data };
}

/** Everything the panes say when there is nothing to edit yet. */
export function InfinitusPanelNotice({ message }: { readonly message: string }) {
  return (
    <p role="status" className="px-3 py-3 text-[13px] text-muted-foreground sm:px-4">
      {message}
    </p>
  );
}

function PrefControlField({
  row,
  disabled,
  onInput,
}: {
  readonly row: PrefRowModel;
  readonly disabled: boolean;
  readonly onInput: (raw: string) => void;
}) {
  const control = row.control;
  switch (control.kind) {
    case "switch":
      return (
        <Switch
          disabled={disabled}
          checked={control.value}
          aria-label={row.label}
          onCheckedChange={(checked) => onInput(String(checked === true))}
        />
      );
    case "select":
      return (
        <Select
          disabled={disabled}
          value={control.value}
          onValueChange={(value) => {
            if (value !== null) onInput(value);
          }}
        >
          <SelectTrigger size="sm" className="w-full sm:w-56" aria-label={row.label}>
            <SelectValue>
              {control.options.find((option) => option.value === control.value)?.label ??
                control.value}
            </SelectValue>
          </SelectTrigger>
          <SelectPopup align="end" alignItemWithTrigger={false}>
            {control.options.map((option) => (
              <SelectItem hideIndicator key={option.value} value={option.value}>
                {option.label}
              </SelectItem>
            ))}
          </SelectPopup>
        </Select>
      );
    case "number":
      return (
        <NumberField
          disabled={disabled}
          value={control.value}
          step={control.integer ? 1 : 0.1}
          size="sm"
          className="w-28"
          onValueCommitted={(value) => {
            if (value !== null) onInput(String(value));
          }}
        >
          <NumberFieldGroup>
            <NumberFieldInput aria-label={row.label} />
          </NumberFieldGroup>
        </NumberField>
      );
    case "text":
      return (
        <DraftInput
          disabled={disabled}
          size="sm"
          className="w-full sm:w-56"
          aria-label={row.label}
          value={control.value}
          onCommit={onInput}
        />
      );
  }
}

interface PendingRestart {
  readonly pref: InfinitusPref;
  readonly label: string;
  readonly value: boolean | number | string;
}

/**
 * The confirm a restart-effect write goes through. Split out so the write path
 * is one prop away from a test: the native app quits itself right after
 * answering such a write, so nothing may be sent on the change alone.
 */
export function RestartConfirmDialog({
  pending,
  onConfirm,
  onCancel,
}: {
  readonly pending: PendingRestart | null;
  readonly onConfirm: () => void;
  readonly onCancel: () => void;
}) {
  if (pending === null) return null;
  return (
    <AlertDialog
      open
      onOpenChange={(open) => {
        if (!open) onCancel();
      }}
    >
      <AlertDialogPopup>
        <AlertDialogHeader>
          <AlertDialogTitle>Relaunch Infinitus?</AlertDialogTitle>
          <AlertDialogDescription>
            “{pending.label}” only takes hold at the next launch, so Infinitus quits and comes
            straight back. Sessions it runs keep going; this page reconnects on its own.
          </AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <Button variant="outline" onClick={onCancel}>
            Cancel
          </Button>
          <Button onClick={onConfirm}>Save and relaunch</Button>
        </AlertDialogFooter>
      </AlertDialogPopup>
    </AlertDialog>
  );
}

export function InfinitusPrefsPanel({
  sectionSlugs,
  title,
  children,
  lead,
  footer,
}: {
  readonly sectionSlugs: ReadonlyArray<string>;
  readonly title: string;
  /** The Engines pane's status list, drawn above the toggles. */
  readonly children?: ReactNode;
  /** Drawn first whatever the native app's state: the Devices pane's pairing
      requests (#710) come from this server, not from Infinitus, and matter
      most while the app is down and a phone is trying to get back in. */
  readonly lead?: ReactNode;
  /** The Devices pane's pairing card, drawn under the prefs once they answer. */
  readonly footer?: ReactNode;
}) {
  const { environmentId, capability, snapshot } = useInfinitusEnvironment();
  const runCommand = useAtomCommand(infinitusEnvironment.command, { reportFailure: false });
  const [writeState, dispatch] = useReducer(reducePrefWrite, initialPrefWriteState);
  const [pendingRestart, setPendingRestart] = useState<PendingRestart | null>(null);

  // Every snapshot both confirms the writes it reports and, for a restart-effect
  // write, carries the unavailable→available pair that ends the relaunch.
  useEffect(() => {
    if (snapshot === null) return;
    dispatch({ type: "snapshot", prefs: snapshot.prefs, available: snapshot.available });
  }, [snapshot]);

  const write = useCallback(
    async (pref: InfinitusPref, value: boolean | number | string) => {
      if (environmentId === null) return;
      const requiresRestart = pref.effect === "restart";
      dispatch({ type: "submit", key: pref.key, value, requiresRestart });
      const { command, args } = prefWriteArgs(pref, value);
      const result = await runCommand({ environmentId, input: { command, args, options: {} } });
      if (result._tag !== "Failure") return;
      const failure = infinitusCommandFailure(result.cause);
      dispatch({ type: "failed", key: pref.key, error: failure.message });
      // A refused engine toggle (engine not installed, proxy key missing) never
      // quit the app, so nothing is waiting for the socket.
      if (requiresRestart && !failure.restarting) dispatch({ type: "relaunchAborted" });
    },
    [environmentId, runCommand],
  );

  const state = infinitusPrefsPanelState({ capability, snapshot });
  const prefs = snapshot?.prefs;
  // Rows are built from the value a row shows — the in-flight write's, else the
  // app's — so the "Default" hint and the reset affordance follow the edit.
  const sections = useMemo(
    () =>
      prefs === undefined
        ? []
        : buildPrefSections(
            {
              ...prefs,
              prefs: prefs.prefs.map((pref) => ({
                ...pref,
                value: displayValue(pref, writeState),
              })),
            },
            sectionSlugs,
          ),
    [prefs, sectionSlugs, writeState],
  );
  const prefsByKey = useMemo(
    () => new Map((prefs?.prefs ?? []).map((pref) => [pref.key, pref] as const)),
    [prefs],
  );

  const submit = useCallback(
    (pref: InfinitusPref, row: PrefRowModel, raw: string) => {
      const parsed = parseControlInput(pref, raw);
      if (!parsed.ok) {
        dispatch({ type: "failed", key: pref.key, error: parsed.reason });
        return;
      }
      // The app relaunches on a CHANGED restart-effect write, so an edit that
      // lands back on the current value is not a write at all.
      if (parsed.value === displayValue(pref, writeState)) return;
      if (row.requiresRestart) {
        setPendingRestart({ pref, label: row.label, value: parsed.value });
        return;
      }
      void write(pref, parsed.value);
    },
    [write, writeState],
  );

  if (state !== "ready") {
    return (
      <SettingsPageContainer>
        {lead}
        <SettingsSection id={`infinitus-${sectionSlugs[0] ?? "prefs"}`} title={title}>
          {snapshot?.available === true ? children : null}
          <InfinitusPanelNotice
            message={infinitusPanelMessage(state, snapshot?.unavailableReason)}
          />
          {state === "unavailable" ? <InfinitusLaunchButton className="px-3 pb-3 sm:px-4" /> : null}
        </SettingsSection>
      </SettingsPageContainer>
    );
  }

  const locked = writeState.relaunching || environmentId === null;

  return (
    <SettingsPageContainer>
      {lead}
      {children}
      {writeState.relaunching ? (
        <p role="status" className="px-3 text-[13px] text-muted-foreground sm:px-4">
          Infinitus is relaunching — this page picks up again when it answers.
        </p>
      ) : null}
      {sections.map((section) => (
        <SettingsSection key={section.slug} id={`infinitus-${section.slug}`} title={section.name}>
          {section.rows.map((row) => {
            const pref = prefsByKey.get(row.key);
            if (pref === undefined) return null;
            const error = writeState.errors.get(row.key);
            const fallback = defaultValue(pref);
            return (
              <SettingsRow
                key={row.key}
                id={`infinitus-pref-${row.key}`}
                title={row.label}
                description={row.description ?? undefined}
                status={
                  <>
                    {row.requiresRestart ? <span>Relaunches Infinitus. </span> : null}
                    {row.isDefault ? null : <span>{prefDefaultHint(row, fallback)}</span>}
                    {error === undefined ? null : (
                      <span className="block text-destructive">{error}</span>
                    )}
                  </>
                }
                resetAction={
                  row.isDefault ? null : (
                    <SettingResetButton
                      label={row.label}
                      disabled={locked}
                      onClick={() => submit(pref, row, String(fallback))}
                    />
                  )
                }
                control={
                  <PrefControlField
                    row={row}
                    disabled={locked}
                    onInput={(raw) => submit(pref, row, raw)}
                  />
                }
              />
            );
          })}
        </SettingsSection>
      ))}
      {footer}
      <RestartConfirmDialog
        pending={pendingRestart}
        onCancel={() => setPendingRestart(null)}
        onConfirm={() => {
          if (pendingRestart !== null) void write(pendingRestart.pref, pendingRestart.value);
          setPendingRestart(null);
        }}
      />
    </SettingsPageContainer>
  );
}
