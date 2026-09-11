import { createCaptureAtoms } from "@t3tools/client-runtime/state/captures";

import { connectionAtomRuntime } from "../connection/runtime";

/** The web app's instance of the captures atoms (#433). */
export const captures = createCaptureAtoms(connectionAtomRuntime);
