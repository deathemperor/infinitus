import {
  type EnvironmentId,
  LEGACY_T3_PROJECT_FILE_NAME,
  type ProjectReadFileResult,
  T3_PROJECT_FILE_NAME,
  type T3ProjectFile,
} from "@infinitus/contracts";
import { parseT3ProjectFile } from "@infinitus/shared/t3ProjectFile";
import { useAtomValue } from "@effect/atom-react";
import { AsyncResult, Atom } from "effect/reactivity";
import { createContext, type ReactNode, useContext } from "react";

import { useEnvironments, usePrimaryEnvironmentId } from "../../state/environments";
import { getProjectFileQueryAtom, optimisticFileAtom } from "../files/projectFilesQueryState";
import { useSettingsProjectGroups } from "./useSettingsProjectGroups";
import { resolveScopedSettingsTargets, selectScopedSettingsEnvironments } from "./scopedSettings";
import { resolveSettingsScope, type SettingsScopeSearch } from "./settingsScope";
import { selectSingleEnvironmentScope } from "./settingsScopeAxis";

type ProjectFileMember = readonly [
  environmentId: EnvironmentId,
  workspaceRoot: string,
  physicalProjectKey: string,
];

const memberProjectFilesAtom = Atom.family((membersKey: string) => {
  const members = JSON.parse(membersKey) as ReadonlyArray<ProjectFileMember>;
  return Atom.make((get) => {
    const files = new Map<string, T3ProjectFile | null>();
    // A pending in-app save overlays the query, like useProjectFileQuery.
    const read = (
      environmentId: EnvironmentId,
      workspaceRoot: string,
      fileName: string,
    ): ProjectReadFileResult | null | "waiting" => {
      const result = get(getProjectFileQueryAtom(environmentId, workspaceRoot, fileName));
      if (result.waiting) return "waiting";
      const data =
        get(optimisticFileAtom(environmentId, workspaceRoot, fileName))?.data ??
        AsyncResult.getOrElse(result, () => null);
      return data === null || data.exists === false ? null : data;
    };
    for (const [environmentId, workspaceRoot, physicalProjectKey] of members) {
      // `infinitus.json` decides when it exists; a checkout carrying only
      // upstream's `t3.json` is read from that, the server's own order.
      const preferred = read(environmentId, workspaceRoot, T3_PROJECT_FILE_NAME);
      if (preferred === "waiting") continue;
      const data = preferred ?? read(environmentId, workspaceRoot, LEGACY_T3_PROJECT_FILE_NAME);
      if (data === "waiting") continue;
      files.set(
        physicalProjectKey,
        data === null || data.truncated ? null : parseT3ProjectFile(data.contents),
      );
    }
    return files;
  }).pipe(Atom.withLabel(`web-settings-member-project-files:${membersKey}`));
});

function useMemberProjectFiles(scope: ReturnType<typeof resolveSettingsScope>) {
  const members = scope.kind === "project" || scope.kind === "checkout" ? scope.members : [];
  return useAtomValue(
    memberProjectFilesAtom(
      JSON.stringify(
        members.map((member): ProjectFileMember => [
          member.environmentId,
          member.workspaceRoot,
          member.physicalProjectKey,
        ]),
      ),
    ),
  );
}

function useResolvedSettingsScope(rawSearch: SettingsScopeSearch, singleEnvironment: boolean) {
  const groups = useSettingsProjectGroups();
  const { environments: availableEnvironments } = useEnvironments();
  const primaryEnvironmentId = usePrimaryEnvironmentId();
  const search = singleEnvironment
    ? selectSingleEnvironmentScope(
        rawSearch,
        resolveSettingsScope(rawSearch, groups, availableEnvironments),
        availableEnvironments,
        primaryEnvironmentId,
      )
    : rawSearch;
  const scope = resolveSettingsScope(search, groups, availableEnvironments);
  const projectFiles = useMemberProjectFiles(scope);
  const selected = selectScopedSettingsEnvironments(
    scope,
    availableEnvironments,
    primaryEnvironmentId,
  );
  const targets = resolveScopedSettingsTargets(scope, selected.connectedEnvironments, projectFiles);
  const target =
    targets.find((candidate) => candidate.environmentId === selected.environment?.environmentId) ??
    targets[0] ??
    null;
  return { scope, groups, search, ...selected, targets, target };
}

const SettingsScopeContext = createContext<
  | (ReturnType<typeof useResolvedSettingsScope> & {
      singleEnvironment: boolean;
      search: SettingsScopeSearch;
      selectScope: (next: SettingsScopeSearch) => void;
    })
  | null
>(null);

export function SettingsScopeProvider({
  search,
  onChange,
  children,
  singleEnvironment = false,
}: {
  singleEnvironment?: boolean;
  search: SettingsScopeSearch;
  onChange: (next: SettingsScopeSearch) => void;
  children: ReactNode;
}) {
  const resolved = useResolvedSettingsScope(search, singleEnvironment);
  const value = { ...resolved, singleEnvironment, selectScope: onChange };
  return <SettingsScopeContext value={value}>{children}</SettingsScopeContext>;
}

export function useOptionalSettingsScope() {
  return useContext(SettingsScopeContext);
}

export function useSettingsScope() {
  const scope = useOptionalSettingsScope();
  if (scope === null) throw new Error("Settings scope must be read inside SettingsScopeProvider.");
  return scope;
}
