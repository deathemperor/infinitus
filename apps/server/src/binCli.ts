import { doctorCommand } from "./cli/doctor.ts";
import * as NodeRuntime from "@effect/platform-node/NodeRuntime";
import * as NodeServices from "@effect/platform-node/NodeServices";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { Argument, Command } from "effect/cli";
import * as CliError from "effect/cli/CliError";

import * as NetService from "@infinitus/shared/Net";
import packageJson from "../package.json" with { type: "json" };
import { acpMcpBridgeCommand, acpMcpCallCommand } from "./cli/acpMcpBridge.ts";
import { authCommand } from "./cli/auth.ts";
import { environmentCommand } from "./cli/environment.ts";
import { appCommand } from "./cli/app.ts";
import { browserCommand } from "./cli/browser.ts";
import { pairCommand } from "./cli/pair.ts";
import { hasCloudPublicConfig } from "./cloud/publicConfig.ts";
import { extendConnectionAttemptTimeout, keepOutboundFetchOnHttp1 } from "./outboundHttp.ts";
import { sharedServerCommandFlags } from "./cli/config.ts";
import { projectCommand } from "./cli/project.ts";
import { threadCommand } from "./cli/thread.ts";
import { runDefaultServerCommand, serveCommand, startCommand } from "./cli/server.ts";
import { updateCommand } from "./cli/update.ts";
import { uninstallCommand } from "./cli/uninstall.ts";
import { serviceLauncherCommand } from "./cli/serviceLauncher.ts";
import { claudeHistoryCommand } from "./cli/claudeHistory.ts";
import { sshHelperCommand } from "./cli/sshHelper.ts";
import { serviceCommand } from "./cli/service.ts";
import { servicePreflightCommand } from "./cli/servicePreflight.ts";
import { themeCommand } from "./cli/theme.ts";
import { traceCommand } from "./cli/trace.ts";
import { triageCommand } from "./cli/triage.ts";
<<<<<<< HEAD
import { CONNECT_NAME, PRODUCT_NAME } from "@infinitus/shared/productName";
=======
import { connectCommand, statusCommand, upCommand } from "./cli/up.ts";
>>>>>>> upstream-sync-2359643cff-upstream-renamed

const layerCliRuntime = Layer.mergeAll(NodeServices.layer, NetService.layer);

const connectPublicConfigMissingMessage = `${CONNECT_NAME} commands are unavailable: this build is missing ${CONNECT_NAME} public configuration.`;

class ConnectPublicConfigMissingError extends CliError.UserError {
  override get message() {
    return connectPublicConfigMissingMessage;
  }
}

const connectUnavailableCommand = Command.make("connect", {
  command: Argument.String("command").pipe(Argument.variadic),
}).pipe(
  Command.withDescription(`${CONNECT_NAME} is unavailable in builds without public configuration.`),
  Command.unlisted,
  Command.withHandler(() =>
    Effect.fail(
      new CliError.ShowHelp({
        commandPath: ["infinitus", "connect"],
        errors: [new ConnectPublicConfigMissingError({ cause: connectPublicConfigMissingMessage })],
      }),
    ),
  ),
);

export const makeCli = ({ cloudEnabled = hasCloudPublicConfig } = {}) =>
<<<<<<< HEAD
  Command.make("infinitus", { ...sharedServerCommandFlags }).pipe(
    Command.withDescription(`Run the ${PRODUCT_NAME} server.`),
=======
  Command.make("t3", { ...sharedServerCommandFlags }).pipe(
    Command.withDescription(
      "Run T3 Code in this terminal and open it in your browser. To use it from your other devices, run `t3 up`.",
    ),
>>>>>>> upstream-sync-2359643cff-upstream-renamed
    Command.withHandler(runDefaultServerCommand),
    Command.withSubcommands([
      Command.make("help").pipe(
        Command.withDescription("Show command help."),
        Command.withHandler(() =>
          Effect.fail(new CliError.ShowHelp({ commandPath: ["infinitus"], errors: [] })),
        ),
      ),
      acpMcpBridgeCommand,
      acpMcpCallCommand,
      startCommand,
      serveCommand,
      appCommand,
      pairCommand,
      authCommand,
      environmentCommand,
      browserCommand,
      projectCommand,
      threadCommand,
      upCommand,
      statusCommand,
      serviceCommand,
      updateCommand,
      uninstallCommand,
      serviceLauncherCommand,
      claudeHistoryCommand,
      sshHelperCommand,

      servicePreflightCommand,
      themeCommand,
      traceCommand,
      doctorCommand,
      triageCommand,
      cloudEnabled ? connectCommand : connectUnavailableCommand,
    ]),
  );

export const cli = makeCli();

export function runCli() {
  extendConnectionAttemptTimeout();
  keepOutboundFetchOnHttp1();
  Command.run(cli, { version: packageJson.version }).pipe(
    Effect.scoped,
    Effect.provide(layerCliRuntime),
    NodeRuntime.runMain,
  );
}
