import type { ReactNode } from "react";
import { act } from "react";
import { create, type ReactTestRenderer } from "react-test-renderer";
import { afterEach, beforeEach, describe, expect, it, vi } from "vite-plus/test";
import { EnvironmentId, type StatsRequest, type StatsSnapshot } from "@infinitus/contracts";
import { statsWindow } from "@infinitus/shared/stats";

const state = vi.hoisted(() => ({ offline: false, unpriced: false }));
vi.mock("@infinitus/client-runtime/state/stats", () => ({
  createStatsAtoms: () => (key: string) => key,
}));
vi.mock("@effect/atom-react", () => ({
  useAtomValue: (key: string) => {
    const { request, selectedIds } = JSON.parse(key) as {
      request: StatsRequest;
      selectedIds: string[] | null;
    };
    return ["mac", "linux"].map((id, i) => {
      const selected = selectedIds === null || selectedIds.includes(id);
      const snapshot: StatsSnapshot = {
        contractVersion: 1,
        ...statsWindow(request),
        timeZone: request.timeZone,
        readAt: "2026-09-22T00:00:00Z",
        historyFrom: "2024-07-01",
        activeDays: [],
        sources: [],
        repositories: [],
        unavailable: [],
        pricing: { status: "fresh", source: "test", knownModels: 1, fetchedAt: null },
        sessions: [
          {
            id,
            sourceId: id,
            updatedAt: 1,
            minutes: [],
            days: [
              {
                key: request.today,
                day: {
                  outputTokens: (i + 1) * 100,
                  usd: state.unpriced ? 0 : (i + 1) * 2,
                  unpricedRecords: state.unpriced ? 1 : 0,
                  pricedRecords: state.unpriced ? 0 : 1,
                },
              },
            ],
          },
        ],
      };
      const offline = id === "linux" && state.offline;
      return {
        environmentId: EnvironmentId.make(id),
        label: id,
        selected,
        status: offline ? "offline" : "ready",
        snapshot: selected && !offline ? snapshot : null,
      };
    });
  },
}));
vi.mock("../../state/server", () => ({ serverEnvironment: {} }));
vi.mock("../../state/presentation", () => ({ environmentPresentations: {} }));
vi.mock("../../rpc/atomRegistry", () => ({ appAtomRegistry: {} }));
vi.mock("../../env", () => ({ isElectron: false }));
vi.mock("../../hooks/useNowMinute", () => ({ useNowMinute: () => "2026-09-22T10:00" }));
vi.mock("../../hooks/useLocalStorage", () => ({ useLocalStorage: () => ["week", vi.fn()] }));
vi.mock("../ui/button", () => ({ Button: "button" }));
vi.mock("../ui/menu", () => ({
  Menu: "div",
  MenuPopup: "div",
  MenuTrigger: "button",
  MenuSeparator: "hr",
  MenuCheckboxItem: ({
    children,
    checked,
    onCheckedChange,
  }: {
    children: ReactNode;
    checked: boolean;
    onCheckedChange: (checked: boolean) => void;
  }) => <button onClick={() => onCheckedChange(!checked)}>{children}</button>,
}));
vi.mock("../ui/scroll-area", () => ({ ScrollArea: "div" }));
vi.mock("../ui/sidebar", () => ({ SidebarInset: "div" }));
vi.mock("../ui/skeleton", () => ({ Skeleton: "div" }));
vi.mock("../WorkspaceBreadcrumb", () => ({
  WorkspaceBreadcrumb: "div",
  WorkspaceBreadcrumbItem: "div",
}));
vi.mock("../WorkspacePageContainer", () => ({ WorkspacePageContainer: "main" }));
vi.mock("../WorkspacePageHeader", () => ({ WorkspacePageHeader: "header" }));
vi.mock("~/components/ui/refresh-icon", () => ({ RefreshIcon: () => null }));
import { StatsPage } from "./StatsPage";

let renderer: ReactTestRenderer | undefined;
beforeEach(() => {
  state.offline = false;
  state.unpriced = false;
});
afterEach(async () => {
  if (renderer) await act(async () => renderer!.unmount());
  renderer = undefined;
});
const content = () =>
  renderer!.root
    .findAll((node) => typeof node.type === "string")
    .flatMap((node) => node.children.filter((child) => typeof child === "string"))
    .join(" ");
async function render() {
  await act(async () => {
    renderer = create(<StatsPage />);
  });
}
describe("Stats environment selection", () => {
  it("combines machines, filters totals, and restores all environments", async () => {
    await render();
    expect(content()).toContain("$6.00");
    const linux = renderer!.root
      .findAllByType("button")
      .find((b) => b.children.join("") === "linux")!;
    await act(async () => linux.props.onClick());
    expect(content()).toContain("$2.00");
    expect(content()).not.toContain("$6.00");
    const all = renderer!.root
      .findAllByType("button")
      .find((b) => b.children.join("") === "All environments")!;
    await act(async () => all.props.onClick());
    expect(content()).toContain("$6.00");
  });
  it("shows partial totals when a machine disconnects and restores them on reconnect", async () => {
    state.offline = true;
    await render();
    expect(content()).toContain("Partial totals.");
    expect(content()).toContain("linux: offline");
    expect(content()).toContain("$2.00");
    state.offline = false;
    await act(async () => renderer!.update(<StatsPage />));
    expect(content()).toContain("$6.00");
    expect(content()).not.toContain("Partial totals.");
  });
  it("does not present unpriced usage as free", async () => {
    state.unpriced = true;
    await render();
    expect(content()).toContain("unpriced responses");
    expect(content()).not.toContain("$0.00");
  });
});
