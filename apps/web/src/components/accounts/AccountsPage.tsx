import { useAtomValue } from "@effect/atom-react";
import {
  infinitusCapabilityAcross,
  infinitusCapabilityOf,
} from "@infinitus/client-runtime/state/infinitusAccounts";
import type { EnvironmentId } from "@infinitus/contracts";
import { useMemo } from "react";

import { isElectron } from "../../env";
import {
  useEnvironments,
  usePrimaryEnvironmentId,
  type EnvironmentPresentation,
} from "../../state/environments";
import { environmentServerConfigsAtom } from "../../state/server";
import { ScrollArea } from "../ui/scroll-area";
import { SidebarInset } from "../ui/sidebar";
import { WorkspaceBreadcrumb, WorkspaceBreadcrumbItem } from "../WorkspaceBreadcrumb";
import { WorkspacePageContainer } from "../WorkspacePageContainer";
import { WorkspacePageHeader } from "../WorkspacePageHeader";
import { AccountsSkeleton, EnvironmentAccounts } from "./EnvironmentAccounts";

/**
 * Every account on every connected machine that runs Infinitus, one group per
 * machine. Each group owns its own snapshot and flows (`EnvironmentAccounts`);
 * this page only decides which machines to draw and what to say when there
 * are none.
 */
export function AccountsPage() {
  const { environments } = useEnvironments();
  const primaryEnvironmentId = usePrimaryEnvironmentId();
  const serverConfigs = useAtomValue(environmentServerConfigsAtom);

  const infinitusEnvironments = useMemo(
    () =>
      environments.filter(
        (environment) =>
          serverConfigs.get(environment.environmentId)?.environment.capabilities.infinitus === true,
      ),
    [environments, serverConfigs],
  );
  // Across every environment: a page that heard only `false` lacks the
  // adapter, one nobody has answered yet is still loading.
  const capability = infinitusCapabilityAcross(
    environments.map((environment) =>
      infinitusCapabilityOf(serverConfigs.get(environment.environmentId)?.environment.capabilities),
    ),
  );

  return (
    <SidebarInset className="h-dvh min-h-0 overflow-hidden overscroll-y-none bg-background text-foreground isolate">
      <div className="flex min-h-0 min-w-0 flex-1 flex-col bg-background text-foreground">
        <WorkspacePageHeader electron={isElectron} className="h-auto">
          <div className="flex w-full min-w-0 items-center gap-x-3 py-2">
            <WorkspaceBreadcrumb ariaLabel="Accounts breadcrumb" className="min-w-0">
              <WorkspaceBreadcrumbItem current>
                <h1>Accounts</h1>
              </WorkspaceBreadcrumbItem>
            </WorkspaceBreadcrumb>
          </div>
        </WorkspacePageHeader>

        <ScrollArea className="min-h-0 flex-1">
          <WorkspacePageContainer width="wide">
            <AccountsList
              capability={capability}
              environments={infinitusEnvironments}
              primaryEnvironmentId={primaryEnvironmentId}
            />
          </WorkspacePageContainer>
        </ScrollArea>
      </div>
    </SidebarInset>
  );
}

function AccountsList({
  capability,
  environments,
  primaryEnvironmentId,
}: {
  readonly capability: boolean | undefined;
  readonly environments: ReadonlyArray<EnvironmentPresentation>;
  readonly primaryEnvironmentId: EnvironmentId | null;
}) {
  if (capability === false) {
    return (
      <section className="max-w-xl rounded-lg border p-4">
        <p className="text-muted-foreground text-sm">
          No connected server has an Infinitus adapter for its platform.
        </p>
      </section>
    );
  }
  if (environments.length === 0) {
    if (capability === undefined) return <AccountsSkeleton />;
    return (
      <p className="text-muted-foreground text-sm">No connected environment runs Infinitus.</p>
    );
  }
  return (
    <div className="flex flex-col gap-10">
      {environments.map((environment) => (
        <EnvironmentAccounts
          key={environment.environmentId}
          environment={environment}
          primary={environment.environmentId === primaryEnvironmentId}
        />
      ))}
    </div>
  );
}
