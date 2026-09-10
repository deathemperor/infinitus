import { createFileRoute } from "@tanstack/react-router";

import { AccountsPage } from "../components/accounts/AccountsPage";

export const Route = createFileRoute("/accounts")({
  component: AccountsPage,
});
