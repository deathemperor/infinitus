import type { EnvironmentId } from "@t3tools/contracts";
import * as Cause from "effect/Cause";
import { useState } from "react";

import { serverEnvironment } from "../../state/server";
import { useAtomCommand } from "../../state/use-atom-command";
import { Button } from "../ui/button";
import { Input } from "../ui/input";
import { Select, SelectItem, SelectPopup, SelectTrigger, SelectValue } from "../ui/select";
import { Switch } from "../ui/switch";
import {
  PROXY_MODEL_SLOTS,
  PROXY_PRESETS,
  withProxyPreset,
  type ProxyDraft,
  type ProxyPresetId,
} from "./proxyProvider";

const NOT_SET = "";

interface ProxyProviderFieldsProps {
  readonly environmentId: EnvironmentId;
  readonly draft: ProxyDraft;
  /** Shown under the fields once the user has tried to save. */
  readonly error: string | null;
  readonly onChange: (draft: ProxyDraft) => void;
}

function proxyErrorDetail(cause: Cause.Cause<unknown>): string {
  const failure: unknown = Cause.squash(cause);
  return typeof failure === "object" &&
    failure !== null &&
    "detail" in failure &&
    typeof failure.detail === "string"
    ? failure.detail
    : "Could not reach the proxy.";
}

/**
 * Fork: "Route through a proxy" for a Claude instance — 9Router, CLIProxyAPI or
 * any Anthropic-compatible endpoint. Loads the proxy's model list so the
 * ANTHROPIC_DEFAULT_*_MODEL slots and the picker model are chosen, not typed.
 */
export function ProxyProviderFields({
  environmentId,
  draft,
  error,
  onChange,
}: ProxyProviderFieldsProps) {
  const listModels = useAtomCommand(serverEnvironment.proxyModels, { reportFailure: false });
  const [models, setModels] = useState<ReadonlyArray<string> | null>(null);
  const [loading, setLoading] = useState(false);
  const [loadError, setLoadError] = useState<string | null>(null);
  /** A loaded list belongs to one base URL; another proxy starts over. */
  const changeProxy = (next: ProxyDraft) => {
    if (next.baseUrl !== draft.baseUrl) {
      setModels(null);
      setLoadError(null);
    }
    onChange(next);
  };

  const loadModels = async () => {
    setLoading(true);
    setLoadError(null);
    const result = await listModels({
      environmentId,
      input: { baseUrl: draft.baseUrl.trim(), apiKey: draft.apiKey.trim() },
    });
    setLoading(false);
    if (result._tag === "Success") {
      setModels(result.value.models);
      return;
    }
    setLoadError(proxyErrorDetail(result.cause));
  };

  const modelField = (
    label: string,
    value: string,
    placeholder: string,
    onValue: (next: string) => void,
  ) => (
    <div key={label} className="grid gap-1.5">
      <span className="text-xs font-medium text-foreground">{label}</span>
      {models ? (
        <Select
          value={value}
          onValueChange={(next) => {
            if (typeof next === "string") onValue(next);
          }}
        >
          <SelectTrigger size="sm" aria-label={label}>
            <SelectValue>{value || "Not set"}</SelectValue>
          </SelectTrigger>
          <SelectPopup align="start" alignItemWithTrigger={false}>
            <SelectItem value={NOT_SET}>Not set</SelectItem>
            {models.map((model) => (
              <SelectItem key={model} value={model}>
                {model}
              </SelectItem>
            ))}
          </SelectPopup>
        </Select>
      ) : (
        <Input
          className="bg-background"
          placeholder={placeholder}
          value={value}
          onChange={(event) => onValue(event.target.value)}
        />
      )}
    </div>
  );

  return (
    <div className="grid gap-3 rounded-lg bg-card p-3 ring-1 ring-black/5 dark:bg-white/3 dark:ring-white/5">
      <label className="flex items-center justify-between gap-3">
        <span className="grid gap-0.5">
          <span className="text-xs font-medium text-foreground">Route through a proxy</span>
          <span className="text-[11px] text-muted-foreground">
            9Router, CLIProxyAPI or any Anthropic-compatible endpoint, with its own config dir.
          </span>
        </span>
        <Switch
          checked={draft.enabled}
          onCheckedChange={(checked) => onChange({ ...draft, enabled: Boolean(checked) })}
          aria-label="Route through a proxy"
        />
      </label>

      {draft.enabled ? (
        <>
          <div className="grid gap-2 sm:grid-cols-[minmax(0,9rem)_minmax(0,1fr)]">
            <div className="grid gap-1.5">
              <span className="text-xs font-medium text-foreground">Proxy</span>
              <Select
                value={draft.preset}
                onValueChange={(next) => {
                  if (typeof next === "string")
                    onChange(withProxyPreset(draft, next as ProxyPresetId));
                }}
              >
                <SelectTrigger size="sm" aria-label="Proxy">
                  <SelectValue>
                    {PROXY_PRESETS.find((preset) => preset.id === draft.preset)?.label}
                  </SelectValue>
                </SelectTrigger>
                <SelectPopup align="start" alignItemWithTrigger={false}>
                  {PROXY_PRESETS.map((preset) => (
                    <SelectItem key={preset.id} value={preset.id}>
                      {preset.label}
                    </SelectItem>
                  ))}
                </SelectPopup>
              </Select>
            </div>
            <label className="grid gap-1.5">
              <span className="text-xs font-medium text-foreground">Base URL</span>
              <Input
                className="bg-background"
                placeholder="http://127.0.0.1:20128/v1"
                value={draft.baseUrl}
                onChange={(event) => changeProxy({ ...draft, baseUrl: event.target.value })}
              />
            </label>
          </div>

          <label className="grid gap-1.5">
            <span className="text-xs font-medium text-foreground">API key</span>
            <div className="flex gap-2">
              <Input
                type="password"
                autoComplete="off"
                className="bg-background"
                value={draft.apiKey}
                onChange={(event) => onChange({ ...draft, apiKey: event.target.value })}
              />
              <Button
                type="button"
                variant="outline"
                size="sm"
                disabled={
                  loading || draft.apiKey.trim().length === 0 || draft.baseUrl.trim().length === 0
                }
                onClick={loadModels}
              >
                {loading ? "Loading…" : "Load models"}
              </Button>
            </div>
            <span className="text-[11px] text-muted-foreground">
              {loadError ??
                (models
                  ? `${models.length} models listed; pick them below.`
                  : "Stored as a sensitive variable on the instance. Load models to pick from the proxy's list.")}
            </span>
          </label>

          <div className="grid gap-2 sm:grid-cols-2">
            {PROXY_MODEL_SLOTS.map((slot) =>
              modelField(
                `${slot.label} slot`,
                draft.slots[slot.key],
                `e.g. kr/claude-${slot.key}`,
                (next) => onChange({ ...draft, slots: { ...draft.slots, [slot.key]: next } }),
              ),
            )}
          </div>
          {modelField(
            "Also list in the model picker",
            draft.pickerModel,
            "e.g. kr/gpt-5.6-sol",
            (next) => onChange({ ...draft, pickerModel: next }),
          )}
          <span className="text-[11px] text-muted-foreground">
            The slots map Claude's model names onto the proxy's. A picker model is added to this
            instance's custom models so you can choose it directly.
          </span>
          {error ? <span className="text-[11px] text-destructive">{error}</span> : null}
        </>
      ) : null}
    </div>
  );
}
