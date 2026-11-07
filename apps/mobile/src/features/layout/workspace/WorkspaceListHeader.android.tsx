import { useEffect, useState } from "react";
import { useNavigation, useNavigationState } from "@react-navigation/native";
import { BackHandler, Keyboard } from "react-native";
import { PRODUCT_NAME } from "@infinitus/shared/productName";

import { AppBar } from "../../../components/ui/AppBar";
import { useWorkspaceConnectionState } from "../../../state/workspace";
import { useHardwareKeyboardCommand } from "../../keyboard/hardwareKeyboardCommands";
import { WorkspaceBrandTitle } from "./WorkspaceBrandTitle";
import { useWorkspaceTabs } from "./WorkspaceTabsContext";
import {
  workspaceListFilterIcon,
  type WorkspaceListHeaderProps,
} from "./WorkspaceListHeader.types";

export function WorkspaceListHeader(props: WorkspaceListHeaderProps) {
  const navigation = useNavigation();
  const workspace = useWorkspaceTabs();
  const isTabActive = workspace?.isTabActive;
  const homeFocused = useNavigationState((state) => state.routes[state.index]?.name === "Home");
  const listFocused =
    homeFocused && (workspace === null || workspace.state.selectedTab === "threads");
  const connectionState = useWorkspaceConnectionState();
  const { search, sidebar } = props;
  const onSearchQueryChange = search.onChangeText;
  const [searchOpen, setSearchOpen] = useState(false);
  const searching = searchOpen || search.value.length > 0;
  const openSearch = () => {
    sidebar?.onRequestVisibility();
    setSearchOpen(true);
    return true;
  };
  useHardwareKeyboardCommand("focusSearch", openSearch);

  const closeSearch = () => {
    onSearchQueryChange("");
    setSearchOpen(false);
    Keyboard.dismiss();
  };

  // oxlint-disable-next-line t3code/no-unreasoned-state-sync -- subscribes to BackHandler while searching to close search on Android back
  useEffect(() => {
    if (!searching || !listFocused) return;
    const subscription = BackHandler.addEventListener("hardwareBackPress", () => {
      // Frozen Home screens can keep effects alive after a detail route opens.
      const state = navigation.getState();
      if (
        !state ||
        state.routes[state.index]?.name !== "Home" ||
        isTabActive?.("threads") === false
      )
        return false;
      if (Keyboard.isVisible()) Keyboard.dismiss();
      else closeSearch();
      return true;
    });
    return () => subscription.remove();
  }, [closeSearch, searching, listFocused, navigation, isTabActive]);

  return (
    <AppBar
      title={PRODUCT_NAME}
      titleContent={
        <WorkspaceBrandTitle
<<<<<<< HEAD:apps/mobile/src/features/home/ThreadListToolbar.android.tsx
          accessibilityLabel={`${PRODUCT_NAME}, Threads`}
=======
          accessibilityLabel={props.accessibilityLabel}
>>>>>>> upstream-sync-67fdc53823-upstream-renamed:apps/mobile/src/features/layout/workspace/WorkspaceListHeader.android.tsx
          onOpenEnvironments={props.onOpenEnvironments}
        />
      }
      search={{
        value: search.value,
        onChangeText: onSearchQueryChange,
        placeholder: search.placeholder,
        accessibilityLabel: search.accessibilityLabel,
        active: searching,
        onOpen: openSearch,
        onClose: closeSearch,
      }}
      menus={
        connectionState.hasConnections
          ? [
              {
                title: "Filter threads",
                icon: workspaceListFilterIcon(props.filter.customized),
                items: props.filter.items,
              },
            ]
          : undefined
      }
    />
  );
}
