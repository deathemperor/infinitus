import type { ProviderDriverKind } from "@infinitus/contracts";

import {
  AcpRegistryAdapterV2Driver,
  type AcpRegistryAdapterV2DriverEnv,
} from "@infinitus/provider-acp-registry/server";
import {
  ClaudeAdapterV2Driver,
  type ClaudeAdapterV2DriverEnv,
} from "./Adapters/ClaudeAdapterV2.ts";
import { CodexAdapterV2Driver, type CodexAdapterV2DriverEnv } from "./Adapters/CodexAdapterV2.ts";
import {
  CursorAdapterV2Driver,
  type CursorAdapterV2DriverEnv,
} from "@infinitus/provider-cursor/server";
import { GrokAdapterV2Driver, type GrokAdapterV2DriverEnv } from "@infinitus/provider-grok/server";
import {
  OpenCodeAdapterV2Driver,
  type OpenCodeAdapterV2DriverEnv,
} from "@infinitus/provider-opencode/server";
import { PiAdapterV2Driver, type PiAdapterV2DriverEnv } from "@infinitus/provider-pi/server";
import type { AnyProviderAdapterDriver } from "@infinitus/provider-core/server/adapterDriver";

export type BuiltInProviderAdapterDriversV2Env =
  | AcpRegistryAdapterV2DriverEnv
  | ClaudeAdapterV2DriverEnv
  | CodexAdapterV2DriverEnv
  | CursorAdapterV2DriverEnv
  | GrokAdapterV2DriverEnv
  | OpenCodeAdapterV2DriverEnv
  | PiAdapterV2DriverEnv;

const BUILT_IN_PROVIDER_ADAPTER_DRIVERS_V2: ReadonlyArray<
  AnyProviderAdapterDriver<BuiltInProviderAdapterDriversV2Env>
> = [
  CodexAdapterV2Driver,
  ClaudeAdapterV2Driver,
  CursorAdapterV2Driver,
  OpenCodeAdapterV2Driver,
  GrokAdapterV2Driver,
  PiAdapterV2Driver,
  AcpRegistryAdapterV2Driver,
];

export const BUILT_IN_PROVIDER_ADAPTER_DRIVER_KINDS_V2: ReadonlySet<ProviderDriverKind> = new Set(
  BUILT_IN_PROVIDER_ADAPTER_DRIVERS_V2.map((driver) => driver.driverKind),
);
