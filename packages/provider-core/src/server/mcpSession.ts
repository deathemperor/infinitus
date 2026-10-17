import type { EnvironmentId, ProviderInstanceId, ThreadId } from "@infinitus/contracts";

export interface McpProviderSessionConfig {
  readonly environmentId: EnvironmentId;
  readonly threadId: ThreadId;
  readonly providerSessionId: string;
  readonly providerInstanceId: ProviderInstanceId;
  readonly endpoint: string;
  readonly authorizationHeader: string;
  /**
   * Adapters read it to keep developer instructions truthful: when the user
   * withholds agent browser access, the prompt must not advertise `preview_*`
   * tools that every call would reject.
   */
  readonly browserToolsAvailable: boolean;
  readonly capabilities?: ReadonlySet<string>;
  readonly agentDeviceEnvironment?: Readonly<Record<string, string>>;
}

export function withAgentDeviceEnvironment(
  base: NodeJS.ProcessEnv,
  config: Pick<McpProviderSessionConfig, "agentDeviceEnvironment"> | undefined,
): NodeJS.ProcessEnv {
  const extra = config?.agentDeviceEnvironment;
  if (!extra) return base;
  const separator = extra.PATH_SEPARATOR ?? ":";
  const basePath = base.PATH ?? base.Path;
  const { PATH: shimDir, PATH_SEPARATOR: _separator, ...rest } = extra;
  return {
    ...base,
    ...rest,
    ...(shimDir ? { PATH: basePath ? `${shimDir}${separator}${basePath}` : shimDir } : {}),
  };
}

/**
 * Fork: the device variables plus the session's identity, which the
 * Infinitus CLI reads inside a thread's terminal. `base` untouched without either.
 */
export function withProviderSessionEnvironment(
  base: NodeJS.ProcessEnv,
  config:
    | {
        readonly agentDeviceEnvironment?: Readonly<Record<string, string>>;
        readonly threadId?: string;
        readonly environmentId?: string;
      }
    | undefined,
): NodeJS.ProcessEnv {
  const withDevice = withAgentDeviceEnvironment(base, config);
  return config?.threadId === undefined
    ? withDevice
    : { ...withDevice, T3_THREAD_ID: config.threadId, T3_ENVIRONMENT_ID: config.environmentId };
}
