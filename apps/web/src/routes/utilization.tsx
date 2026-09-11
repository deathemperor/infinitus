import { createFileRoute } from "@tanstack/react-router";

import { UtilizationPage } from "../components/utilization/UtilizationPage";

export const Route = createFileRoute("/utilization")({
  component: UtilizationPage,
});
