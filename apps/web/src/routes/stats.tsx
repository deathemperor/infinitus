import { createFileRoute } from "@tanstack/react-router";

import { StatsPage } from "../components/stats/StatsPage";

export const Route = createFileRoute("/stats")({
  component: StatsPage,
});
