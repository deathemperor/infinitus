/**
 * PiAdapter — shape type for the Pi provider adapter.
 *
 * Like the other drivers, the adapter is bundled per instance as a captured
 * closure by {@link ../Drivers/PiDriver} rather than exposed as a
 * `Context.Service`; this interface is the naming anchor for that bundle.
 *
 * @module PiAdapter
 */
import type { ProviderAdapterError } from "../Errors.ts";
import type { ProviderAdapterShape } from "./ProviderAdapter.ts";

export type PiAdapterShape = ProviderAdapterShape<ProviderAdapterError>;
