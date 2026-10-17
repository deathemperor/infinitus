import { secretSettingsFields } from "@infinitus/contracts";
import * as AzureDevOps from "@infinitus/source-control-azure-devops/client/definition";
import * as Bitbucket from "@infinitus/source-control-bitbucket/client/definition";
import type { SourceControlClientDefinition } from "@infinitus/source-control-core/client/definition";
import * as Forgejo from "@infinitus/source-control-forgejo/client/definition";
import * as GitCafe from "@infinitus/source-control-gitcafe/client/definition";
import * as GitHub from "@infinitus/source-control-github/client/definition";
import * as GitLab from "@infinitus/source-control-gitlab/client/definition";

const definitions: ReadonlyArray<SourceControlClientDefinition> = [
  GitHub.definition,
  GitLab.definition,
  AzureDevOps.definition,
  Bitbucket.definition,
  Forgejo.definition,
  GitCafe.definition,
];

export const SOURCE_CONTROL_HOST_SECRET_FIELDS: ReadonlyMap<
  string,
  ReadonlyArray<string>
> = new Map(
  definitions.flatMap((definition) => {
    const fields = definition.settings ? secretSettingsFields(definition.settings) : [];
    return fields.length > 0 ? [[definition.kind, fields] as const] : [];
  }),
);

export interface SourceControlHostSecretSlot {
  readonly kind: string;
  readonly field: string;
  readonly serverHost: string | null;
}

/** The secret store entry for one slot; names stay stable across releases. */
export function sourceControlHostSecretName(slot: SourceControlHostSecretSlot): string {
  const encode = (value: string) => Buffer.from(value, "utf8").toString("base64url");
  return slot.serverHost === null
    ? `source-control-${encode(slot.kind)}-${encode(slot.field)}`
    : `source-control-${encode(slot.kind)}-${encode(slot.field)}-${encode(slot.serverHost.trim().toLowerCase())}`;
}

export function readSecretFieldValues(
  value: unknown,
): ReadonlyArray<readonly [serverHost: string | null, value: string]> {
  if (typeof value === "string") return [[null, value]];
  if (value === null || typeof value !== "object" || Array.isArray(value)) return [];
  return Object.entries(value).flatMap(([serverHost, entry]) =>
    typeof entry === "string" ? [[serverHost.trim().toLowerCase(), entry] as const] : [],
  );
}

export function writeSecretFieldValues(
  original: unknown,
  values: ReadonlyArray<readonly [serverHost: string | null, value: string]>,
): unknown {
  if (typeof original === "string") return values[0]?.[1] ?? "";
  return Object.fromEntries(values.map(([serverHost, value]) => [serverHost ?? "", value]));
}
