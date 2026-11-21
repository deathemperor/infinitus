import { UserButton, useAuth } from "@clerk/react";
import { T, useMessages } from "gt-react";
import { LogInIcon, RotateCwIcon } from "lucide-react";

import { hasCloudPublicConfig } from "../../cloud/publicConfig";
import { SidebarMenu, SidebarMenuButton, SidebarMenuItem } from "../ui/sidebar";
import { retryClerkLoad, useClerkLoadFailed } from "./clerkLoadFailure";
import { T3_CONNECT_ACCOUNT_PAGES } from "./InfinitusConnectAccountPages";
import { useInfinitusConnectAuthPrompt } from "./useInfinitusConnectAuthPrompt";
import { CONNECT_NAME } from "@infinitus/shared/productName";

export function InfinitusConnectSidebarSignIn() {
  if (!hasCloudPublicConfig()) return null;

  return <ConfiguredInfinitusConnectSidebarSignIn />;
}

export function InfinitusConnectSidebarAvatar() {
  if (!hasCloudPublicConfig()) return null;

  return <ConfiguredInfinitusConnectSidebarAvatar />;
}

function ConfiguredInfinitusConnectSidebarAvatar() {
  const { isLoaded, isSignedIn } = useAuth();
  const m = useMessages();

  if (!isLoaded || !isSignedIn) return null;

  return (
    <UserButton
      appearance={{
        elements: {
          avatarBox: "size-7",
          // Clerk's unlayered trigger reset (padding, radius, background) beats layered utilities.
          userButtonTrigger: "mb-1! rounded-lg! p-1! hover:bg-sidebar-row-hover!",
        },
      }}
    >
      {T3_CONNECT_ACCOUNT_PAGES.map((page) => (
        <UserButton.UserProfilePage
          key={page.url}
          label={m(page.label)}
          labelIcon={page.icon}
          url={page.url}
        >
          {page.content}
        </UserButton.UserProfilePage>
      ))}
    </UserButton>
  );
}

function ConfiguredInfinitusConnectSidebarSignIn() {
  const { isLoaded, isSignedIn } = useAuth();
  const loadFailed = useClerkLoadFailed();
  const { openAuthPrompt } = useInfinitusConnectAuthPrompt();

  if (loadFailed) {
    return (
      <SidebarMenu>
        <SidebarMenuItem>
          <SidebarMenuButton onClick={retryClerkLoad}>
            <RotateCwIcon />
<<<<<<< HEAD
            <span>Retry {CONNECT_NAME}</span>
=======
            <span>
              <T>Retry T3 Connect</T>
            </span>
>>>>>>> upstream-sync-9f9ebf61fb-upstream-renamed
          </SidebarMenuButton>
        </SidebarMenuItem>
      </SidebarMenu>
    );
  }
  if (!isLoaded || isSignedIn) return null;

  return (
    <SidebarMenu>
      <SidebarMenuItem>
        <SidebarMenuButton onClick={openAuthPrompt}>
          <LogInIcon />
<<<<<<< HEAD
          <span>Sign in to {CONNECT_NAME}</span>
=======
          <span>
            <T>Sign in to T3 Connect</T>
          </span>
>>>>>>> upstream-sync-9f9ebf61fb-upstream-renamed
        </SidebarMenuButton>
      </SidebarMenuItem>
    </SidebarMenu>
  );
}
