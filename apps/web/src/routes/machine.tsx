import { createFileRoute } from "@tanstack/react-router";

import { MachinePage } from "../components/machine/MachinePage";

export const Route = createFileRoute("/machine")({
  component: MachinePage,
});
