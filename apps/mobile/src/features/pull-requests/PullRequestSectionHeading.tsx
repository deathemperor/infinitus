import type { ReactNode } from "react";
import { AppText } from "../../components/ui/AppText";

export function PullRequestSectionHeading({ children }: { readonly children: ReactNode }) {
  return <AppText className="text-base font-infinitus-semibold">{children}</AppText>;
}
