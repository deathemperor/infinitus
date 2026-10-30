import { UserButton, useAuth } from "@clerk/react";
import { LogInIcon } from "lucide-react";

import { hasCloudPublicConfig } from "../../cloud/publicConfig";
import { SidebarMenu, SidebarMenuButton, SidebarMenuItem } from "../ui/sidebar";
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
          label={page.label}
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
  const { openAuthPrompt } = useInfinitusConnectAuthPrompt();

  if (!isLoaded || isSignedIn) return null;

  return (
<<<<<<< HEAD
    <>
      <SidebarMenu>
        <SidebarMenuItem>
          <SidebarMenuButton onClick={openAuthPrompt}>
            <LogInIcon />
            <span>Sign in to {CONNECT_NAME}</span>
          </SidebarMenuButton>
        </SidebarMenuItem>
      </SidebarMenu>
      {authPrompt}
    </>
=======
    <SidebarMenu>
      <SidebarMenuItem>
        <SidebarMenuButton onClick={openAuthPrompt}>
          <LogInIcon />
          <span>Sign in to T3 Connect</span>
        </SidebarMenuButton>
      </SidebarMenuItem>
    </SidebarMenu>
>>>>>>> upstream-sync-32ecd7172-upstream-renamed
  );
}
