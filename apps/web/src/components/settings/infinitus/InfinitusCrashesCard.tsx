/**
 * "Crash reports" on Settings › Devices: the crashes and hangs the
 * Mac recorded — the phone's, filed over `crash-report` from MetricKit, and
 * the Mac app's own diagnostic reports — read over `infinitus.command`'s
 * `crashes` verb. Nothing leaves that Mac unless you copy a report: the list
 * carries no raw diagnostic, and Copy asks for the one report's transcript
 * when it is pressed. Read-only — the Mac keeps the newest 50 and prunes
 * itself.
 *
 * @module InfinitusCrashesCard
 */
import { useCallback, useEffect, useState } from "react";

import { writeTextToClipboard } from "~/hooks/useCopyToClipboard";
import { infinitusEnvironment } from "~/state/infinitus";
import { useAtomCommand } from "~/state/use-atom-command";

import { Button } from "../../ui/button";
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

  const copy = useCallback(
    async (id: string) => {
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
        await writeTextToClipboard(transcript, "crash report");
        setError(null);
        setCopied(id);
      } catch (cause) {
        setError(cause instanceof Error ? cause.message : "Could not copy the report.");
      }
    },
    [environmentId, runCommand],
  );

  useEffect(() => {
    if (copied === null) return;
    const timer = setTimeout(() => setCopied(null), 2_000);
    return () => clearTimeout(timer);
  }, [copied]);

  if (!supported) return null;

  const shown = reports?.slice(0, SHOWN) ?? [];

  return (
    <SettingsSection id="infinitus-crashes" title="Crash reports">
      <div className="flex flex-col gap-3 px-3 py-3 text-sm sm:px-4">
        {reports !== null && shown.length === 0 ? (
          <p role="status" className="text-muted-foreground">
            {EMPTY_NOTICE}
          </p>
        ) : null}
        {shown.length === 0 ? null : (
          <ul className="flex flex-col gap-2">
            {shown.map((report) => (
              <li
                key={report.id}
                className="flex flex-wrap items-center gap-x-4 gap-y-1 rounded-lg border border-border/60 px-3 py-2"
              >
                <div className="flex min-w-0 flex-1 flex-col">
                  <span className="truncate text-foreground">{crashSummary(report)}</span>
                  <span className="truncate text-muted-foreground">{crashDetail(report)}</span>
                </div>
                <Button variant="outline" size="sm" onClick={() => void copy(report.id)}>
                  {copied === report.id ? "Copied" : "Copy report"}
                </Button>
              </li>
            ))}
          </ul>
        )}
        <p className="text-muted-foreground">
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
