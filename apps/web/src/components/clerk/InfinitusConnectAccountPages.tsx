import { useAuth, useClerk } from "@clerk/react";
<<<<<<< HEAD
import { CONNECT_NAME } from "@infinitus/shared/productName";
import { ServerIcon, SmartphoneIcon } from "lucide-react";
=======
import { MessageSquareIcon, ServerIcon, SmartphoneIcon } from "lucide-react";
>>>>>>> upstream-sync-c1876b57c-upstream-renamed
import { type ReactNode, useState } from "react";
import { createPortal } from "react-dom";

import { MobileClientsUserProfilePage } from "./MobileClientsUserProfilePage";
import { T3ChatUserProfilePage } from "./T3ChatUserProfilePage";
import { InfinitusConnectUserProfilePage } from "./InfinitusConnectUserProfilePage";

export const T3_CONNECT_ACCOUNT_PAGES = [
  {
    label: "Mobile clients",
    url: "mobile-clients",
    icon: <SmartphoneIcon className="size-4" />,
    content: <MobileClientsUserProfilePage />,
  },
  {
    label: CONNECT_NAME,
    url: "t3-connect",
    icon: <ServerIcon className="size-4" />,
    content: <InfinitusConnectUserProfilePage />,
  },
  {
    label: "T3 Chat",
    url: "t3-chat",
    icon: <MessageSquareIcon className="size-4" />,
    content: <T3ChatUserProfilePage />,
  },
] as const;

export type InfinitusConnectAccountPageUrl = (typeof T3_CONNECT_ACCOUNT_PAGES)[number]["url"];

type PortalTargets = Readonly<Record<string, HTMLDivElement | undefined>>;

/** Keep portals rendered while the modal can open; Clerk owns the custom-page DOM nodes. */
export function useInfinitusConnectAccountPage(): {
  readonly open: ((page?: InfinitusConnectAccountPageUrl) => void) | null;
  readonly portals: ReactNode;
} {
  const clerk = useClerk();
  const { isSignedIn } = useAuth();
  const [targets, setTargets] = useState<PortalTargets>({});

  const open = (page: InfinitusConnectAccountPageUrl = "t3-connect") => {
    const setTarget = (key: string, element: HTMLDivElement | undefined) =>
      setTargets((current) => ({ ...current, [key]: element }));
    clerk.openUserProfile({
      __experimental_startPath: `/${page}`,
      customPages: T3_CONNECT_ACCOUNT_PAGES.map((page) => ({
        label: page.label,
        url: page.url,
        mount: (element: HTMLDivElement) => setTarget(`content:${page.url}`, element),
        unmount: () => setTarget(`content:${page.url}`, undefined),
        mountIcon: (element: HTMLDivElement) => setTarget(`icon:${page.url}`, element),
        unmountIcon: () => setTarget(`icon:${page.url}`, undefined),
      })),
    });
  };

  const portals = T3_CONNECT_ACCOUNT_PAGES.flatMap((page) => {
    const content = targets[`content:${page.url}`];
    const icon = targets[`icon:${page.url}`];
    return [
      content ? createPortal(page.content, content, `content:${page.url}`) : null,
      icon ? createPortal(page.icon, icon, `icon:${page.url}`) : null,
    ];
  });

  return { open: isSignedIn ? open : null, portals };
}
