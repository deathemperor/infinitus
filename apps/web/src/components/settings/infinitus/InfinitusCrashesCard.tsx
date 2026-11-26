/**
 * Crash reports on Settings › Devices: the crashes and hangs the Mac recorded (the phone's, filed
 * over `crash-report`, and the Mac app's own), read via the `crashes` verb. Nothing leaves that Mac
 * unless you copy a report; the list carries no raw diagnostic. Read-only.
 *
 * @module InfinitusCrashesCard
 */
import { useEffect, useState } from "react";

import { namedClipboardTarget, writeTextToClipboard } from "~/hooks/useCopyToClipboard";
import { infinitusEnvironment } from "~/state/infinitus";
import { useAtomCommand } from "~/state/use-atom-command";

import { Button } from "../../ui/button";
import { ITEM_ROW_CLASSNAME, ITEM_ROW_INNER_CLASSNAME } from "../itemRows";
import { SettingsSection } from "../settingsLayout";
import {
  type CrashReport,
  crashDetail,
  crashesInput,
  crashesSupported,
  crashSummary,
  crashTranscriptInput,
  parseCrashes,
} from "./crashes.logic";
import { useInfinitusEnvironment } from "./InfinitusPrefsPanel";
import { infinitusCommandFailure } from "./panel.logic";

const EMPTY_NOTICE =
  "None. The phone reports its own crashes on its next launch; the Mac app's land here after a relaunch.";
const SHOWN = 10;

export function InfinitusCrashesCard() {
  const { environmentId, snapshot } = useInfinitusEnvironment();
  const runCommand = useAtomCommand(infinitusEnvironment.command, { reportFailure: false });
  const [reports, setReports] = useState<ReadonlyArray<CrashReport> | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [copied, setCopied] = useState<string | null>(null);

  const supported = snapshot !== null && snapshot.available && crashesSupported(snapshot.commands);

  // The reports are not part of the snapshot, so they are asked for once the
  // app is answering. They only change on a crash, which takes a relaunch.
  // oxlint-disable-next-line t3code/no-unreasoned-state-sync -- asks the engine over the socket for its crash reports once it answers; a late reply is ignored after unmount
  useEffect(() => {
    if (!supported || environmentId === null) return;
    let live = true;
    void (async () => {
      const result = await runCommand({ environmentId, input: crashesInput() });
      if (!live) return;
      if (result._tag === "Failure") {
        setError(infinitusCommandFailure(result.cause).message);
        return;
      }
      const parsed = parseCrashes(result.value.result);
      if (parsed === null) {
        setError("Infinitus answered the crash reports with a shape this build cannot read.");
        return;
      }
      setError(null);
      setReports(parsed);
    })();
    return () => {
      live = false;
    };
  }, [environmentId, runCommand, supported]);

  const copy = async (id: string) => {
    if (environmentId === null) return;
    setCopied(null);
    const result = await runCommand({ environmentId, input: crashTranscriptInput(id) });
    if (result._tag === "Failure") {
      setError(infinitusCommandFailure(result.cause).message);
      return;
    }
    const transcript = parseCrashes(result.value.result)?.[0]?.transcript;
    if (transcript === undefined) {
      setError("That report is no longer on the Mac.");
      return;
    }
    try {
      await writeTextToClipboard(transcript, namedClipboardTarget("crash report"));
      setError(null);
      setCopied(id);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not copy the report.");
    }
  };

  // oxlint-disable-next-line t3code/no-unreasoned-state-sync -- timer that clears the copied confirmation after two seconds
  useEffect(() => {
    if (copied === null) return;
    const timer = setTimeout(() => setCopied(null), 2_000);
    return () => clearTimeout(timer);
  }, [copied]);

  if (!supported) return null;

  const shown = reports?.slice(0, SHOWN) ?? [];

  return (
    <SettingsSection id="infinitus-crashes" title="Crash reports">
      {reports !== null && shown.length === 0 ? (
        <p role="status" className={`${ITEM_ROW_CLASSNAME} text-sm text-muted-foreground`}>
          {EMPTY_NOTICE}
        </p>
      ) : null}
      {shown.map((report) => (
        <div key={report.id} className={ITEM_ROW_CLASSNAME}>
          <div className={ITEM_ROW_INNER_CLASSNAME}>
            <div className="flex min-w-0 flex-1 flex-col text-sm">
              <span className="truncate text-foreground">{crashSummary(report)}</span>
              <span className="truncate text-xs text-muted-foreground">{crashDetail(report)}</span>
            </div>
            <Button variant="outline" size="sm" onClick={() => void copy(report.id)}>
              {copied === report.id ? "Copied" : "Copy report"}
            </Button>
          </div>
        </div>
      ))}
      <div className={`${ITEM_ROW_CLASSNAME} text-xs text-muted-foreground`}>
        <p>
          Nothing leaves the Mac on its own. Copy a report to read it, or to hand it to a session
          for triage.
        </p>
        {error === null ? null : (
          <p role="alert" className="text-destructive">
            {error}
          </p>
        )}
      </div>
    </SettingsSection>
  );
}
