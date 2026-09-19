import { createFilesystemEnvironmentAtoms } from "@infinitus/client-runtime/state/filesystem";

import { connectionAtomRuntime } from "../connection/runtime";

export const filesystemEnvironment = createFilesystemEnvironmentAtoms(connectionAtomRuntime);
