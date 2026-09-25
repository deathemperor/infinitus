import type { EnvironmentId } from "@infinitus/contracts";
import * as Cause from "effect/Cause";
import { useState } from "react";

import { serverEnvironment } from "../../state/server";
import { useAtomCommand } from "../../state/use-atom-command";
import { Button } from "../ui/button";
import { Checkbox } from "../ui/checkbox";
import { Input } from "../ui/input";
import { Select, SelectItem, SelectPopup, SelectTrigger, SelectValue } from "../ui/select";
import { Switch } from "../ui/switch";
import {
  PROXY_MODEL_SLOTS,
  PROXY_PRESETS,
  withProxyPreset,
  type ProxyDraft,
  type ProxyDriver,
  type ProxyPresetId,
} from "./proxyProvider";

const NOT_SET = "";

/** Typed picker models, before a list is loaded: comma or newline separated. */
function splitTypedModels(value: string): ReadonlyArray<string> {
  return value
    .split(/[\n,]/)
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0);
}

interface ProxyProviderFieldsProps {
  /** Claude gets the ANTHROPIC_DEFAULT_*_MODEL slots; Pi has no such mapping. */
  readonly driver: ProxyDriver;
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
 * Fork: "Route through a proxy" for a Claude or Pi instance — 9Router,
 * CLIProxyAPI or any compatible endpoint. Loads the proxy's model list so the
 * ANTHROPIC_DEFAULT_*_MODEL slots (Claude) and the picker models are chosen,
 * not typed.
 */
export function ProxyProviderFields({
  driver,
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

  const picked = new Set(draft.pickerModels);
  const allPicked = models !== null && models.length > 0 && models.every((m) => picked.has(m));
  /** Models the proxy did not list (typed before the list loaded) keep their place first. */
  const unlisted = draft.pickerModels.filter((entry) => !(models ?? []).includes(entry));
  const withPicked = (next: ReadonlySet<string>): ReadonlyArray<string> => [
    ...unlisted.filter((entry) => next.has(entry)),
    ...(models ?? []).filter((entry) => next.has(entry)),
  ];
  const togglePicked = (model: string, checked: boolean): ReadonlyArray<string> => {
    const next = new Set(picked);
    if (checked) next.add(model);
    else next.delete(model);
    return withPicked(next);
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
          <span className="text-2xs text-muted-foreground">
            {driver === "pi"
              ? "9Router, CLIProxyAPI or any OpenAI-compatible endpoint, with its own config dir."
              : "9Router, CLIProxyAPI or any Anthropic-compatible endpoint, with its own config dir."}
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
                placeholder="http://127.0.0.1:20128"
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
            <span className="text-2xs text-muted-foreground">
              {loadError ??
                (models
                  ? `${models.length} models listed; pick them below.`
                  : "Stored as a sensitive variable on the instance. Load models to pick from the proxy's list.")}
            </span>
          </label>

          {driver === "claude" ? (
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
          ) : null}
          <div className="grid gap-1.5">
            <div className="flex items-center justify-between gap-2">
              <span className="text-xs font-medium text-foreground">
                Also list in the model picker
              </span>
              {models && models.length > 0 ? (
                <Button
                  type="button"
                  variant="ghost"
                  size="xs"
                  onClick={() =>
                    onChange({
                      ...draft,
                      pickerModels: allPicked
                        ? unlisted
                        : withPicked(new Set([...draft.pickerModels, ...models])),
                    })
                  }
                >
                  {allPicked ? "Clear all" : "Select all"}
                </Button>
              ) : null}
            </div>
            {models && models.length > 0 ? (
              <ul className="grid max-h-48 gap-0.5 overflow-y-auto rounded-md bg-background p-1 ring-1 ring-black/5 dark:ring-white/5">
                {models.map((model) => (
                  <li key={model}>
                    <label className="flex cursor-pointer items-center gap-2 rounded-md px-1.5 py-1 text-sm hover:bg-muted/60">
                      <Checkbox
                        checked={picked.has(model)}
                        onCheckedChange={(next) =>
                          onChange({ ...draft, pickerModels: togglePicked(model, Boolean(next)) })
                        }
                      />
                      <span className="truncate">{model}</span>
                    </label>
                  </li>
                ))}
              </ul>
            ) : (
              <Input
                placeholder="e.g. kr/gpt-5.6-sol, kr/claude-opus-5"
                value={draft.pickerModels.join(", ")}
                onChange={(event) =>
                  onChange({ ...draft, pickerModels: splitTypedModels(event.target.value) })
                }
              />
            )}
          </div>
          <span className="text-2xs text-muted-foreground">
            {driver === "claude"
              ? "The slots map Claude's model names onto the proxy's. Picked models are added to this instance's custom models so you can choose them directly."
              : "Picked models are added to this instance's custom models as proxy/<model>; pick at least one, since Pi lists only declared models."}
          </span>
          {error ? <span className="text-2xs text-destructive">{error}</span> : null}
        </>
      ) : null}
    </div>
  );
}
