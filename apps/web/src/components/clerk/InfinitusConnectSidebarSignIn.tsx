import { UserButton, useAuth } from "@clerk/react";
import { LogInIcon, ServerIcon, SmartphoneIcon } from "lucide-react";

import { hasCloudPublicConfig } from "../../cloud/publicConfig";
import { SidebarMenu, SidebarMenuButton, SidebarMenuItem } from "../ui/sidebar";
import { MobileClientsUserProfilePage } from "./MobileClientsUserProfilePage";
import { InfinitusConnectUserProfilePage } from "./InfinitusConnectUserProfilePage";
import { useInfinitusConnectAuthPrompt } from "./useInfinitusConnectAuthPrompt";
<<<<<<< HEAD
import { CONNECT_NAME } from "@infinitus/shared/productName";
=======
>>>>>>> upstream-sync-803f94e78-upstream-renamed

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
