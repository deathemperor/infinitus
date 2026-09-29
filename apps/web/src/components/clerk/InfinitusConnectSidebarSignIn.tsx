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
          userButtonTrigger: "rounded-lg p-1 hover:bg-sidebar-row-hover",
        },
      }}
    >
<<<<<<< HEAD
      <UserButton.UserProfilePage
        label="Mobile clients"
        labelIcon={<SmartphoneIcon className="size-4" />}
        url="mobile-clients"
      >
        <MobileClientsUserProfilePage />
      </UserButton.UserProfilePage>
      <UserButton.UserProfilePage
        label={CONNECT_NAME}
        labelIcon={<ServerIcon className="size-4" />}
        url="t3-connect"
      >
        <InfinitusConnectUserProfilePage />
      </UserButton.UserProfilePage>
=======
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
>>>>>>> upstream-sync-d2c9281b8-upstream-renamed
    </UserButton>
  );
}

function ConfiguredInfinitusConnectSidebarSignIn() {
  const { isLoaded, isSignedIn } = useAuth();
  const { authPrompt, openAuthPrompt } = useInfinitusConnectAuthPrompt();

  if (!isLoaded || isSignedIn) return null;

  return (
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
  );
}
