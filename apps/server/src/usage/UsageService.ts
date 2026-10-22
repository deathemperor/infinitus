<<<<<<< HEAD
// @effect-diagnostics-next-line nodeBuiltinImport:off -- Effect's Crypto has no sha256 digest.
import * as NodeCrypto from "node:crypto";
import { StatsRequest, StatsSnapshot, type StatsSession } from "@infinitus/contracts";
import { statsWindow, shiftStatsDay, statsDayFormatter } from "@infinitus/shared/stats";
import {
  activityCollector,
  emptyTranscriptActivity,
  summarizeStatsSession,
} from "../stats/statsTranscripts.ts";
import { makeStatsRepositoryScanner } from "../stats/statsRepositories.ts";
import * as ProcessRunner from "../processRunner.ts";
/**
 * UsageService - reads every driver's usage history and returns priced usage
 * buckets.
 *
 * Each built-in driver with a `usage` reader contributes its sources, including
 * work driven outside T3 Code. A `transcripts` reader names JSONL directories
 * that this service streams itself; a `scan` reader reads its own sources.
 *
 * JSONL transcripts are append-only, so parsed records are memoised per file by
 * `(size, mtime)`. A cold 30-day scan of ~1.4 GB lands around 2-3 seconds; warm
 * scans only reparse files that changed, and a file that merely grew resumes
 * from its cached parse position so only the appended bytes are read.
 *
 * A scan reader with a slow source (an account API) may answer from its own
 * cache and mark itself `refreshing` while a background refresh runs;
 * `awaitRefresh` waits for that refresh instead.
 *
 * @module UsageService
 */
=======
>>>>>>> upstream-sync-43879d970-upstream-renamed
import * as NodeOS from "node:os";

import {
  type ProviderInstanceConfig,
  ProviderInstanceId,
  USAGE_CONTRACT_VERSION,
  type ServerSettings as ServerSettingsValue,
  type UsageProviderKind,
  type UsageSource,
  type UsagePricing,
  type UsageSummary,
  type UsageSummaryInput,
  type UsageTokenTotals,
  UsageReadError,
} from "@infinitus/contracts";
import * as HostProcess from "@infinitus/shared/HostProcess";
import * as Cause from "effect/Cause";
import * as Clock from "effect/Clock";
import * as Context from "effect/Context";
import * as DateTime from "effect/DateTime";
import * as Deferred from "effect/Deferred";
import * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";
import * as Fiber from "effect/Fiber";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Path from "effect/Path";
import * as Schema from "effect/Schema";
import * as Semaphore from "effect/Semaphore";
import { HttpClient, HttpClientResponse } from "effect/http";

import { writeFileStringAtomically } from "@infinitus/shared/atomicWrite";
import * as ServerConfig from "../config.ts";
import { UsageAttribution } from "../infinitus/Services/UsageAttribution.ts";
import * as ServerSettings from "../serverSettings.ts";
import { BUILT_IN_USAGE_DRIVERS, type BuiltInUsageReadersEnv } from "../provider/builtInDrivers.ts";
import type { ProviderDriver } from "@infinitus/provider-core/server/driver";
import { mergeProviderInstanceEnvironment } from "@infinitus/provider-core/server/instanceEnvironment";
import {
  EMPTY_TOTALS,
  type ProviderUsageInstance,
  type TranscriptUsageFormat,
  type UsageRecord,
} from "@infinitus/provider-core/server/usage";
import { resolveModelAliases, UsageAggregator } from "./usageAggregation.ts";
import {
  createOverrideRateTable,
  parseRateTable,
  priceUsage,
  type RateTable,
} from "./usagePricing.ts";
import {
  listTranscriptFiles,
  readDirectoryVolumeId,
  readTranscriptRecords,
} from "./usageTranscriptReader.ts";
import {
  decodeScanCache,
  dedupeWithinFile,
  LEGACY_SCAN_CACHE_FILE_NAMES,
  makeScanCacheWriter,
  pruneScanCache,
  SCAN_CACHE_FILE_NAME,
  type CachedFile,
  type ScanCache,
} from "./usageScanCache.ts";

const LITELLM_RATES_URL =
  "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json";
const LITELLM_RATES_API_URL =
  "https://api.github.com/repos/BerriAI/litellm/contents/model_prices_and_context_window.json?ref=main";

const RATES_TTL_MS = 24 * 60 * 60 * 1000;

const RATES_REFRESH_FLOOR_MS = 60 * 1000;

/**
 * Files are filtered by mtime before opening. The slack covers a session whose
 * last write lands just before local midnight on the window's first day.
 */
const MTIME_SLACK_MS = 36 * 60 * 60 * 1000;
const MAX_HOURLY_WINDOW_MS = 24 * 60 * 60 * 1000;

<<<<<<< HEAD
/** Fork: Stats compares calendar years, so retain two years plus boundary slack. */
const CACHE_RETENTION_DAYS = 800;

/**
 * The longest window the UI offers, 90 days, plus its `MTIME_SLACK_MS`, rounded
 * up: how far back the scan readers (Cursor account history, Antigravity) are
 * asked to keep (upstream's cache retention).
 */
const SCAN_READER_RETENTION_DAYS = 92;
=======
const CACHE_RETENTION_DAYS = 92;
>>>>>>> upstream-sync-43879d970-upstream-renamed

const TRANSCRIPT_READ_CONCURRENCY = 4;

const transcriptReaders = BUILT_IN_USAGE_DRIVERS.flatMap((driver) =>
  driver.usage?.kind === "transcripts" ? [{ driver, reader: driver.usage }] : [],
);

const scanReaders = BUILT_IN_USAGE_DRIVERS.flatMap((driver) =>
  driver.usage?.kind === "scan" ? [{ driver, reader: driver.usage }] : [],
);

const transcriptFormats = new Map(
  transcriptReaders.map(({ reader }) => [reader.provider, reader.format] as const),
);

interface TranscriptSource {
  readonly provider: UsageProviderKind;
  readonly format: TranscriptUsageFormat<unknown>;
  readonly dir: string;
  readonly volumeId: string;
  readonly fileName?: string;
}

const RatesCacheFile = Schema.Struct({
  fetchedAtMs: Schema.Number,
  document: Schema.Unknown,
});
const decodeRatesCache = Schema.decodeUnknownEffect(
  Schema.fromJsonString(RatesCacheFile as unknown as Schema.Codec<typeof RatesCacheFile.Type>),
);
const encodeRatesCache = Schema.encodeEffect(
  Schema.fromJsonString(RatesCacheFile as unknown as Schema.Codec<typeof RatesCacheFile.Type>),
);

const ScanCacheJson = Schema.fromJsonString(Schema.Unknown as unknown as Schema.Codec<unknown>);
const decodeScanCacheFile = Schema.decodeUnknownEffect(ScanCacheJson);
const encodeUsageRecordKey = Schema.encodeSync(ScanCacheJson);
const CachedSource = Schema.Struct({ dir: Schema.String, volumeId: Schema.String });

function isLaterRead(a: CachedFile, b: CachedFile): boolean {
  return a.mtimeMs > b.mtimeMs || (a.mtimeMs === b.mtimeMs && a.size > b.size);
}

const sharedSessionProviders: ReadonlySet<UsageProviderKind> = new Set(
  transcriptReaders.flatMap(({ reader }) =>
    reader.format.sharedSessionsAcrossFiles ? [reader.provider] : [],
  ),
);

/**
 * Only these need cross-file dedupe keys: within one file the occurrence count
 * already keeps every key unique, so keying the rest would only build and hash
 * a string for each of their records.
 */
function sharedSessions(
  files: readonly { readonly records: readonly UsageRecord[] }[],
): ReadonlySet<string> {
  const firstFile = new Map<string, number>();
  const shared = new Set<string>();
  for (const [index, file] of files.entries()) {
    let previous = "";
    for (const { provider, sessionId } of file.records) {
      if (!sharedSessionProviders.has(provider) || sessionId === previous || sessionId.length === 0)
        continue;
      previous = sessionId;
      const first = firstFile.get(sessionId);
      if (first === undefined) firstFile.set(sessionId, index);
      else if (first !== index) shared.add(sessionId);
    }
  }
  return shared;
}
const decodeCachedSources = Schema.decodeUnknownOption(
  Schema.Struct({ sources: Schema.Record(Schema.String, CachedSource) }),
);

export class UsageService extends Context.Service<
  UsageService,
  {
    readonly readStats: (input: StatsRequest) => Effect.Effect<StatsSnapshot, UsageReadError>;
    readonly readSummary: (input: UsageSummaryInput) => Effect.Effect<UsageSummary, UsageReadError>;
    readonly refreshRates: Effect.Effect<UsagePricing>;
    /**
     * Fork (#834): the Claude transcripts named by session id
     * (`<sessionId>.jsonl` under each configured Claude account's projects
     * tree), each summed and priced; a session with no transcript or no usage
     * records is absent.
     */
    readonly readSessionUsage: (input: {
      readonly sessionIds: ReadonlyArray<string>;
    }) => Effect.Effect<ReadonlyMap<string, SessionUsage>, UsageReadError>;
  }
>()("t3/usage/UsageService") {}

/**
 * Fork (#834): one Claude session's transcript summed — the usage
 * backfill's input. `costUsd` is null when no record could be priced;
 * `lastAt` is the newest record's time.
 */
export interface SessionUsage {
  readonly totals: UsageTokenTotals;
  readonly costUsd: number | null;
  /** Distinct, first seen first. */
  readonly models: ReadonlyArray<string>;
  readonly lastAt: string;
}

/** A session id is a file name here; anything else is not looked for. */
const SESSION_ID = /^[A-Za-z0-9_-]{1,128}$/;

/** Sums one session's records, dropping repeats by `dedupeKey`, and prices what it can. */
function foldSessionUsage(
  records: ReadonlyArray<UsageRecord>,
  rates: RateTable,
  overrides: RateTable,
): SessionUsage | null {
  const seen = new Set<string>();
  let totals: UsageTokenTotals = EMPTY_TOTALS;
  let costUsd: number | null = null;
  const models: string[] = [];
  let lastMs = 0;
  let any = false;
  for (const record of records) {
    if (record.dedupeKey !== null) {
      if (seen.has(record.dedupeKey)) continue;
      seen.add(record.dedupeKey);
    }
    any = true;
    totals = {
      uncachedInputTokens: totals.uncachedInputTokens + record.totals.uncachedInputTokens,
      cachedInputTokens: totals.cachedInputTokens + record.totals.cachedInputTokens,
      cacheCreationTokens: totals.cacheCreationTokens + record.totals.cacheCreationTokens,
      outputTokens: totals.outputTokens + record.totals.outputTokens,
      reasoningTokens: totals.reasoningTokens + record.totals.reasoningTokens,
    };
    const priced = priceUsage(rates, record, overrides);
    if (priced.costSource !== "unpriced") costUsd = (costUsd ?? 0) + priced.costUsd;
    if (record.model.length > 0 && !models.includes(record.model)) models.push(record.model);
    if (record.timestampMs > lastMs) lastMs = record.timestampMs;
  }
  if (!any) return null;
  return { totals, costUsd, models, lastAt: DateTime.formatIso(DateTime.makeUnsafe(lastMs)) };
}

const EMPTY_PRICING: UsagePricing = {
  status: "unavailable",
  source: LITELLM_RATES_URL,
  fetchedAt: null,
  knownModels: 0,
};

const layerTest = Layer.succeed(
  UsageService,
  UsageService.of({
    readStats: (input) =>
      Effect.succeed({
        contractVersion: 1,
        readAt: "1970-01-01T00:00:00.000Z",
        timeZone: input.timeZone,
        ...statsWindow(input),
        historyFrom: input.today,
        activeDays: [],
        sources: [],
        sessions: [],
        repositories: [],
        pricing: EMPTY_PRICING,
        unavailable: [],
      }),
    readSummary: (input) =>
      Effect.succeed({
        contractVersion: USAGE_CONTRACT_VERSION,
        readAt: "1970-01-01T00:00:00.000Z",
        timeZone: input.timeZone,
        sinceDay: input.sinceDay,
        untilDay: input.untilDay,
        buckets: [],
        sources: [],
        pricing: EMPTY_PRICING,
        scanDurationMs: 0,
      }),
    refreshRates: Effect.succeed(EMPTY_PRICING),
    readSessionUsage: () => Effect.succeed(new Map()),
  }),
);

export const make = Effect.gen(function* () {
  // Per-account spend (#779) needs a swap timeline only a server next to
  // Infinitus can have; without the service the summary simply has no accounts.
  const attribution = yield* Effect.serviceOption(UsageAttribution);
  const fileSystem = yield* FileSystem.FileSystem;
  const path = yield* Path.Path;
  const config = yield* ServerConfig.ServerConfig;
  const settingsService = yield* ServerSettings.ServerSettingsService;
  const httpClient = yield* HttpClient.HttpClient;
  const hostEnvironment = yield* HostProcess.Environment;
  const readerContext = yield* Effect.context<BuiltInUsageReadersEnv>();

  const fileCache: ScanCache = new Map();
<<<<<<< HEAD
  const statsSessions = new Map<
    string,
    { entry: CachedFile; key: string; records: readonly UsageRecord[]; session: StatsSession }
  >();
  const runner = yield* Effect.serviceOption(ProcessRunner.ProcessRunner);
  const scanRepositories = Option.isSome(runner) ? makeStatsRepositoryScanner(runner.value) : null;
=======
  // Reads from concurrent windows can still hold the original record after it is corrected.
  const resolvedRecords = new WeakMap<UsageRecord, UsageRecord>();
  const correctedRecord = (record: UsageRecord) => resolvedRecords.get(record) ?? record;
  const correctedBatch = (records: readonly UsageRecord[]) =>
    records.some((record) => resolvedRecords.has(record)) ? records.map(correctedRecord) : records;
>>>>>>> upstream-sync-43879d970-upstream-renamed
  const sourceCache = new Map<string, typeof CachedSource.Type>();
  let cacheDirty = false;
  const isWithinDirectory = (filePath: string, dir: string) => {
    const relative = path.relative(dir, filePath);
    return relative !== ".." && !relative.startsWith(".." + path.sep) && !path.isAbsolute(relative);
  };

  const ratesCachePath = path.join(config.stateDir, "usage-model-rates.json");
  const scanCachePath = path.join(config.stateDir, SCAN_CACHE_FILE_NAME);
  const writeCacheFile = (filePath: string, contents: string) =>
    writeFileStringAtomically({ filePath, contents }).pipe(
      Effect.provideService(FileSystem.FileSystem, fileSystem),
      Effect.provideService(Path.Path, path),
    );
  let rates: RateTable = new Map();
  let ratesFetchedAtMs: number | null = null;
  let ratesLastFailedAtMs: number | null = null;
  let ratesStatus: UsagePricing["status"] = "unavailable";
  const ratesLock = yield* Semaphore.make(1);

  const pricing = (): UsagePricing => ({
    status: ratesStatus,
    source: LITELLM_RATES_URL,
    fetchedAt:
      ratesFetchedAtMs === null ? null : DateTime.formatIso(DateTime.makeUnsafe(ratesFetchedAtMs)),
    knownModels: rates.size,
  });

  const fetchRates = (url: string, accept = "application/json") =>
    httpClient.get(url, { headers: { accept } }).pipe(
      Effect.flatMap(HttpClientResponse.filterStatusOk),
      Effect.flatMap((response) => response.json),
      Effect.map((document) => {
        const parsed = parseRateTable(document);
        return parsed.size > 0 ? { document, parsed } : null;
      }),
      Effect.timeout(10_000),
      Effect.catchCause(() => Effect.succeed(null)),
    );

  const loadRates = Effect.fn("UsageService.loadRates")(function* (force: boolean) {
    const now = yield* Clock.currentTimeMillis;
    const maxAgeMs = force ? RATES_REFRESH_FLOOR_MS : RATES_TTL_MS;
    if (ratesFetchedAtMs !== null && now - ratesFetchedAtMs < maxAgeMs) return;

    if (ratesFetchedAtMs === null) {
      const fromDisk = yield* fileSystem.readFileString(ratesCachePath).pipe(
        Effect.flatMap((raw) => decodeRatesCache(raw)),
        Effect.catchCause(() => Effect.succeed(null)),
      );
      if (fromDisk !== null) {
        const parsed = parseRateTable(fromDisk.document);
        if (parsed.size > 0) {
          rates = parsed;
          ratesFetchedAtMs = fromDisk.fetchedAtMs;
          ratesStatus = "cached";
          if (now - fromDisk.fetchedAtMs < maxAgeMs) return;
        }
      }
    }

    if (ratesLastFailedAtMs !== null && now - ratesLastFailedAtMs < RATES_REFRESH_FLOOR_MS) return;

    let fetched = yield* fetchRates(LITELLM_RATES_URL);
    if (fetched === null) {
      fetched = yield* fetchRates(LITELLM_RATES_API_URL, "application/vnd.github.raw+json");
    }
    if (fetched === null) {
      ratesLastFailedAtMs = yield* Clock.currentTimeMillis;
      if (rates.size > 0) ratesStatus = "cached";
      return;
    }

    rates = fetched.parsed;
    ratesFetchedAtMs = now;
    ratesLastFailedAtMs = null;
    ratesStatus = "fresh";

    yield* encodeRatesCache({ fetchedAtMs: now, document: fetched.document }).pipe(
      Effect.flatMap((contents) => writeCacheFile(ratesCachePath, contents)),
      Effect.ignoreCause,
    );
  });

  const ensureRates = (force: boolean) => ratesLock.withPermit(loadRates(force));

  const refreshRates = ensureRates(true).pipe(
    Effect.map(pricing),
    Effect.withSpan("UsageService.refreshRates"),
  );

  const readSettings = settingsService.getSettings.pipe(
    Effect.catchCause(
      (cause) =>
        new UsageReadError({
          reason: "scanFailed",
          detail: "Server settings could not be read.",
          cause: Cause.squash(cause),
        }),
    ),
  );

  const usageInstances = Effect.fn("UsageService.usageInstances")(function* <Config>(
    driver: ProviderDriver<Config, unknown, unknown>,
    settings: ServerSettingsValue,
  ) {
    const entries: Array<
      readonly [ProviderInstanceId, Pick<ProviderInstanceConfig, "config" | "environment">, boolean]
    > = Object.entries(settings.providerInstances)
      .filter(([, instance]) => instance.driver === driver.driverKind)
      .map(([id, instance]) => [ProviderInstanceId.make(id), instance, true] as const);
    if (!Object.hasOwn(settings.providerInstances, driver.driverKind)) {
      entries.push([ProviderInstanceId.make(driver.driverKind), {}, false]);
    }
    const decodeConfig = Schema.decodeUnknownOption(driver.configSchema);
    return yield* Effect.forEach(
      entries,
      Effect.fnUntraced(function* ([instanceId, instance, configured]) {
        const instanceConfig: ProviderUsageInstance<Config> = {
          instanceId,
          config: Option.getOrUndefined(decodeConfig(instance.config ?? {})),
          environment: yield* mergeProviderInstanceEnvironment(
            instance.environment,
            hostEnvironment,
          ),
          configured,
        };
        return instanceConfig;
      }),
    );
  });

  const resolveTranscriptDirs = Effect.fn("UsageService.resolveTranscriptDirs")(function* (
    settings: ServerSettingsValue,
    retentionCutoffMs: number,
  ) {
    const dirs: Array<TranscriptSource> = [];
    const seen = new Set<string>();
    for (const { driver, reader } of transcriptReaders) {
      const { provider, format } = reader;
      const directories = yield* Effect.forEach(
        yield* usageInstances(driver, settings),
        (instance) => reader.directories(instance),
      );
      for (const { dir: directory, fileName } of directories.flat()) {
        const sourceKey = provider + "\0" + directory;
        const previous = sourceCache.get(sourceKey);
        const dir = yield* fileSystem
          .realPath(directory)
          .pipe(Effect.orElseSucceed(() => previous?.dir ?? directory));
        const currentVolumeId = yield* Effect.promise(() => readDirectoryVolumeId(dir));
        const hasRetainedHistory = fileCache
          .entries()
          .some(
            ([filePath, entry]) =>
              entry.provider === provider &&
              entry.mtimeMs >= retentionCutoffMs &&
              (entry.records.length + entry.tailRecords.length > 0 || entry.malformedRecords > 0) &&
              isWithinDirectory(filePath, dir),
          );
        const volumeId =
          previous?.dir === dir && (hasRetainedHistory || !currentVolumeId)
            ? previous.volumeId || currentVolumeId
            : currentVolumeId;
        if (previous?.dir !== dir || previous.volumeId !== volumeId) {
          sourceCache.set(sourceKey, { dir, volumeId });
          cacheDirty = true;
        }
        const key = `${provider}\0${dir}`;
        if (seen.has(key)) continue;
        seen.add(key);
        dirs.push({
          provider,
          format,
          dir,
          volumeId,
          ...(fileName === undefined ? {} : { fileName }),
        });
      }
    }
    return dirs;
  });

  /**
   * `Effect.cached` makes concurrent first readers await the same load rather
   * than each seeing a "loaded" flag set before the read finished and cold
   * scanning against an empty cache.
   */
  const ensureScanCacheLoaded = yield* Effect.cached(
    Effect.gen(function* () {
      const readDocument = (filePath: string) =>
        fileSystem.readFileString(filePath).pipe(
          Effect.flatMap((raw) => decodeScanCacheFile(raw)),
          Effect.catchCause(() => Effect.succeed(null)),
        );
      let document = yield* readDocument(scanCachePath);
      for (const fileName of LEGACY_SCAN_CACHE_FILE_NAMES) {
        if (document !== null) break;
        document = yield* readDocument(path.join(config.stateDir, fileName));
        cacheDirty = document !== null;
      }
      if (document === null) return;
      for (const [path, entry] of decodeScanCache(document, transcriptFormats)) {
        fileCache.set(path, entry);
      }
      const sources = decodeCachedSources(document);
      if (Option.isSome(sources)) {
        for (const [key, source] of Object.entries(sources.value.sources))
          sourceCache.set(key, source);
      }
    }),
  );

  const writeScanCache = makeScanCacheWriter();
  // Scans with different windows can finish together; serializing the writes
  // keeps an older snapshot from landing after a newer one.
  const persistLock = yield* Semaphore.make(1);

  // The dirty flag is cleared before encoding, so a change while the write is
  // in flight marks it dirty again. A failed write restores the flag, so the
  // next persist retries instead of leaving disk stale.
  const persistCaches = Effect.gen(function* () {
    if (cacheDirty) {
      cacheDirty = false;
      yield* Effect.sync(() =>
        writeScanCache(fileCache, { sources: Object.fromEntries(sourceCache) }),
      ).pipe(
        Effect.flatMap((contents) => writeCacheFile(scanCachePath, contents)),
        Effect.catchCause(() =>
          Effect.sync(() => {
            cacheDirty = true;
          }),
        ),
      );
    }
  }).pipe(persistLock.withPermit, Effect.withSpan("UsageService.persistCaches"));

  const pendingPersists = new Set<Fiber.Fiber<void>>();
  const schedulePersist = Effect.forkDetach(persistCaches).pipe(
    Effect.map((fiber) => {
      pendingPersists.add(fiber);
      fiber.addObserver(() => pendingPersists.delete(fiber));
    }),
  );
  const awaitPersisted = Effect.suspend(() => Fiber.awaitAll([...pendingPersists])).pipe(
    Effect.asVoid,
  );
  // A write still running when the service shuts down finishes first, so the
  // next start does not lose the last scan.
  yield* Effect.addFinalizer(() => awaitPersisted);

  /**
<<<<<<< HEAD
   * Parses one transcript, reusing the cached result when it is unchanged.
   *
   * A file that only grew re-parses from the cached position, so an actively
   * written multi-hundred-megabyte rollout costs its appended bytes per scan
   * rather than a full re-read. The reader verifies the position's guard bytes
   * and silently restarts from byte 0 when they no longer match.
   *
   * A fresh parse comes back as `update` for the caller to cache, with the
   * entry it was built from. Reads run concurrently, and the caller stores
   * updates in walk order rather than completion order: saved records of
   * deleted transcripts aggregate in cache order, where the first copy of a
   * duplicate wins.
   *
   * Fork (#659): with `withStats`, or once a file carries activity, the parse
   * also folds the Stats activity facts, kept beside the records in the cache.
=======
   * Reads run concurrently, and the caller stores updates in walk order rather
   * than completion order: saved records of deleted transcripts aggregate in
   * cache order, where the first copy of a duplicate wins.
>>>>>>> upstream-sync-43879d970-upstream-renamed
   */
  const readFileRecords = Effect.fn("UsageService.readFileRecords")(function* (
    filePath: string,
    size: number,
    mtimeMs: number,
    provider: UsageProviderKind,
    format: TranscriptUsageFormat<unknown>,
<<<<<<< HEAD
    withStats = false,
  ): Effect.Effect<{
=======
  ): Effect.fn.Return<{
>>>>>>> upstream-sync-43879d970-upstream-renamed
    readonly records: readonly UsageRecord[];
    readonly malformedRecords: number;
    readonly failed?: true;
    readonly update?: { readonly entry: CachedFile; readonly replaces: CachedFile | undefined };
<<<<<<< HEAD
  }> =>
    Effect.gen(function* () {
      const cached = fileCache.get(filePath);
      // Provider is part of the identity: if both providers were ever pointed
      // at one directory, a hit parsed by the other parser must not be reused.
      if (
        cached &&
        cached.size === size &&
        cached.mtimeMs === mtimeMs &&
        cached.provider === provider &&
        (!withStats || cached.activity !== undefined)
      ) {
        return {
          records:
            cached.tailRecords.length === 0
              ? cached.records
              : [...cached.records, ...cached.tailRecords],
        };
      }

      // Only a strictly grown file may resume. Same size with a new mtime, or
      // a shrunken file, means rewritten content; re-parse it whole.
      const resumeFrom =
        cached !== undefined &&
        cached.provider === provider &&
        size > cached.size &&
        // Activity includes the prior tail; replay the file so it is not observed twice.
        (cached.activity === undefined || cached.position.resumeOffset >= cached.size) &&
        (!withStats || cached.activity !== undefined)
          ? cached.position
          : undefined;

      const activity =
        withStats || cached?.activity !== undefined
          ? activityCollector(
              cached?.activity ?? emptyTranscriptActivity(/[\\/]subagents[\\/]/.test(filePath)),
            )
          : undefined;
      const observer =
        activity === undefined
          ? undefined
          : {
              reset: activity.reset,
              line: (line: string, state: unknown) => activity.line(line, provider, state),
            };
      const parsed = yield* Effect.promise(() =>
        readTranscriptRecords(filePath, format, resumeFrom, { observer }),
      );
      // A read failure is not an empty transcript: caching it under this
      // (size, mtime) would silently drop the file's usage until it changes.
      if (parsed === null)
        return {
          records: cached?.provider === provider ? [...cached.records, ...cached.tailRecords] : [],
          failed: true,
        };

      // Stored already de-duplicated within the file, which is 99% of all
      // duplicates. The aggregator still runs the cross-file dedupe pass. One
      // seen set spans the cached base, the new lines, and the tail so a
      // resumed parse dedupes exactly like a full one.
      const base = parsed.resumed && cached !== undefined ? cached.records : [];
      const seen = new Set<string>();
      const records = dedupeWithinFile([...base, ...parsed.records], seen);
      const tailRecords = dedupeWithinFile(parsed.tailRecords, seen);

      return {
        records: tailRecords.length === 0 ? records : [...records, ...tailRecords],
        update: {
          entry: {
            size,
            mtimeMs,
            provider,
            records,
            tailRecords,
            position: parsed.position,
            ...(activity === undefined ? {} : { activity: activity.finish() }),
          },
          replaces: cached,
        },
=======
  }> {
    const cached = fileCache.get(filePath);
    // Provider is part of the identity: if both providers were ever pointed
    // at one directory, a hit parsed by the other parser must not be reused.
    if (
      cached &&
      cached.size === size &&
      cached.mtimeMs === mtimeMs &&
      cached.provider === provider
    ) {
      return {
        records:
          cached.tailRecords.length === 0
            ? cached.records
            : [...cached.records, ...cached.tailRecords],
        malformedRecords: cached.malformedRecords,
>>>>>>> upstream-sync-43879d970-upstream-renamed
      };
    }

    // Only a strictly grown file may resume. Same size with a new mtime, or
    // a shrunken file, means rewritten content; re-parse it whole.
    const resumeFrom =
      cached !== undefined && cached.provider === provider && size > cached.size
        ? cached.position
        : undefined;

    const parsed = yield* Effect.promise(() => readTranscriptRecords(filePath, format, resumeFrom));
    // A read failure is not an empty transcript: caching it under this
    // (size, mtime) would silently drop the file's usage until it changes.
    if (parsed === null)
      return {
        records: cached?.provider === provider ? [...cached.records, ...cached.tailRecords] : [],
        malformedRecords: cached?.provider === provider ? cached.malformedRecords : 0,
        failed: true,
      };

    if (parsed.resumed && cached !== undefined && cached.tailRecords.length > 0) {
      // Completing a tentative line reparses it. Reuse its saved correction only when the
      // same usage is emitted again, without putting inferred tiers in the parser state.
      const reparsed = [...parsed.records, ...parsed.tailRecords];
      const identity = (record: UsageRecord) =>
        encodeUsageRecordKey([
          record.provider,
          record.sessionId,
          record.timestampMs,
          record.model,
          record.rateModel,
          record.totals,
          record.reportedCostUsd,
          record.dedupeKey,
        ]);
      for (const [index, previous] of cached.tailRecords.entries()) {
        const record = reparsed[index];
        const corrected = correctedRecord(previous);
        if (
          record?.unresolvedServiceTierTurnId !== undefined &&
          corrected.unresolvedServiceTierTurnId === undefined &&
          identity(record) === identity(corrected)
        ) {
          resolvedRecords.set(record, corrected);
        }
      }
    }
    const base = parsed.resumed && cached !== undefined ? cached.records : [];
    const seen = new Set<string>();
    const records = dedupeWithinFile([...base, ...parsed.records], seen);
    const tailRecords = dedupeWithinFile(parsed.tailRecords, seen);

    return {
      records: tailRecords.length === 0 ? records : [...records, ...tailRecords],
      malformedRecords: parsed.malformedRecords,
      update: {
        entry: {
          size,
          mtimeMs,
          provider,
          records,
          tailRecords,
          malformedRecords: parsed.malformedRecords,
          position: parsed.position,
        },
        replaces: cached,
      },
    };
  });

  interface ScannedDir {
    /** Fork: transcript files the walk or parse could not read; Stats reports them as skipped. */
    readonly failedFiles?: number;
    readonly provider: UsageProviderKind;
    readonly dir: string;
    readonly volumeId: string;
    readonly hostId?: string;
    readonly status?: UsageSource["status"];
    readonly message?: string;
    readonly action?: UsageSource["action"];
    readonly files:
      | readonly {
          readonly path: string;
          readonly records: readonly UsageRecord[];
          readonly malformedRecords: number;
        }[]
      | null;
    readonly refreshing?: true;
  }

  const scanTranscriptDir = Effect.fn("UsageService.scanTranscriptDir")(function* (
    source: TranscriptSource,
    windowStartMs: number,
    withStats = false,
  ) {
    const { provider, format, dir, volumeId, fileName } = source;
    const exists = yield* fileSystem
      .exists(dir)
      .pipe(Effect.catchCause(() => Effect.succeed(false)));
    if (!exists) return { provider, dir, volumeId, files: null } satisfies ScannedDir;
    const { files, failedPaths } = yield* Effect.promise(() =>
      listTranscriptFiles(dir, windowStartMs, fileName === undefined ? undefined : { fileName }),
    );
    const read = yield* Effect.forEach(
      files,
      (file) =>
        readFileRecords(file.path, file.size, file.mtimeMs, provider, format, withStats).pipe(
          Effect.map((result) => ({ path: file.path, ...result })),
        ),
      { concurrency: TRANSCRIPT_READ_CONCURRENCY },
    );
    const parsedFiles = read.map(({ path, records, malformedRecords, update }) => {
      if (update === undefined) return { path, records, malformedRecords };
      // A scan of another window may have cached its own read of this file
      // meanwhile. Then keep whichever read saw the later file, so a slower
      // scan never replaces newer usage with older.
      const current = fileCache.get(path);
      if (
        current === update.replaces ||
        current === undefined ||
        isLaterRead(update.entry, current)
      ) {
        fileCache.set(path, {
          ...update.entry,
          records: correctedBatch(update.entry.records),
          tailRecords: correctedBatch(update.entry.tailRecords),
        });
        cacheDirty = true;
      }
      return { path, records, malformedRecords };
    });
    const unread = failedPaths + read.filter((file) => file.failed).length;
    return {
      provider,
      dir,
      volumeId,
      files: parsedFiles,
      failedFiles: unread,
      ...(unread > 0
        ? {
            status: "partial",
            message: `${unread} transcript path(s) could not be read; usage may be incomplete.`,
          }
        : {}),
    } satisfies ScannedDir;
  });

  const collectDirs = Effect.fn("UsageService.collectDirs")(function* (
    windowStartMs: number,
    settings: ServerSettingsValue,
    retentionCutoffMs: number,
    awaitRefresh: boolean,
    withStats = false,
  ) {
    const dirs = yield* resolveTranscriptDirs(settings, retentionCutoffMs).pipe(
      Effect.provideContext(readerContext),
    );

    // Fork: the long transcript retention is for Stats; the scan readers
    // (an account API's history) keep upstream's window.
    const scanRetentionCutoffMs = Math.max(
      retentionCutoffMs,
      (yield* Clock.currentTimeMillis) - SCAN_READER_RETENTION_DAYS * 24 * 60 * 60 * 1000,
    );
    const scans = Effect.forEach(
      scanReaders,
      ({ driver, reader }) =>
        usageInstances(driver, settings)
          .pipe(
            Effect.flatMap((instances) =>
              reader.scan({
                instances,
                settings,
                windowStartMs,
                retentionCutoffMs: scanRetentionCutoffMs,
                awaitRefresh,
              }),
            ),
          )
          .pipe(
            Effect.flatMap((sources) =>
              Effect.forEach(sources, ({ volumeId, ...source }) =>
                Effect.map(
                  volumeId === undefined
                    ? Effect.promise(() => readDirectoryVolumeId(source.dir))
                    : Effect.succeed(volumeId),
                  (resolved): ScannedDir => ({
                    ...source,
                    files: source.files?.map((file) => ({ ...file, malformedRecords: 0 })) ?? null,
                    provider: reader.provider,
                    volumeId: resolved,
                  }),
                ),
              ),
            ),
            Effect.provideContext(readerContext),
          ),
      { concurrency: "unbounded" },
    );

    // Independent sources scan together. Transcript directories go one at a
    // time, so open files stay at `TRANSCRIPT_READ_CONCURRENCY`. The result
    // keeps this order, since aggregation keeps the first copy of a duplicate.
    const [transcripts, scanDirs] = yield* Effect.all(
      [Effect.forEach(dirs, (dir) => scanTranscriptDir(dir, windowStartMs, withStats)), scans],
      { concurrency: "unbounded" },
    );
    const scanned: readonly ScannedDir[] = [...transcripts, ...scanDirs.flat()];
    return scanned;
  });

  const scanSummary = Effect.fn("UsageService.scanSummary")(function* (
    input: UsageSummaryInput,
    settings: ServerSettingsValue,
  ) {
    if (input.sinceDay > input.untilDay) {
      return yield* new UsageReadError({
        reason: "invalidWindow",
        detail: `sinceDay '${input.sinceDay}' is after untilDay '${input.untilDay}'`,
      });
    }

    let hourlyWindow: { readonly sinceTimeMs: number; readonly untilTimeMs: number } | null = null;
    if (input.resolution === "hour") {
      const sinceTime =
        input.sinceTime === undefined ? Option.none() : DateTime.make(input.sinceTime);
      const untilTime =
        input.untilTime === undefined ? Option.none() : DateTime.make(input.untilTime);
      if (Option.isNone(sinceTime) || Option.isNone(untilTime)) {
        return yield* new UsageReadError({
          reason: "invalidWindow",
          detail: "Hourly usage requires valid sinceTime and untilTime instants",
        });
      }
      const sinceTimeMs = DateTime.toEpochMillis(sinceTime.value);
      const untilTimeMs = DateTime.toEpochMillis(untilTime.value);
      const durationMs = untilTimeMs - sinceTimeMs;
      if (durationMs <= 0 || durationMs > MAX_HOURLY_WINDOW_MS) {
        return yield* new UsageReadError({
          reason: "invalidWindow",
          detail: "Hourly usage window must be greater than zero and at most 24 hours",
        });
      }
      hourlyWindow = { sinceTimeMs, untilTimeMs };
    }

    const startedAtMs = yield* Clock.currentTimeMillis;
    yield* ensureScanCacheLoaded;

    const hostId = NodeOS.hostname();
    const windowStart = DateTime.make(`${input.sinceDay}T00:00:00Z`);
    if (Option.isNone(windowStart)) {
      return yield* new UsageReadError({
        reason: "invalidWindow",
        detail: `sinceDay '${input.sinceDay}' is not a valid date`,
      });
    }
    const windowStartMs =
      (hourlyWindow?.sinceTimeMs ?? DateTime.toEpochMillis(windowStart.value)) - MTIME_SLACK_MS;
    // Where the window ends for the swap count (#779): the hourly bound, or
    // the last instant `untilDay` can still be that day in any zone (UTC-12
    // ends it 36 h after UTC midnight). Days here are the client's zone, so
    // this is a bound, not a boundary; the caption says "in this window".
    const windowEndMs =
      hourlyWindow?.untilTimeMs ?? Date.parse(`${input.untilDay}T00:00:00Z`) + 36 * 60 * 60 * 1000;

    const retentionCutoffMs = startedAtMs - CACHE_RETENTION_DAYS * 24 * 60 * 60 * 1000;

<<<<<<< HEAD
    // Pricing only matters once records are aggregated, so the rate table
    // loads while transcripts stream instead of gating them: a cold rates
    // fetch on a slow network no longer delays the scan by its own timeout.
    const [, scannedDirs, timeline] = yield* Effect.all(
=======
    const [, scannedDirs] = yield* Effect.all(
>>>>>>> upstream-sync-43879d970-upstream-renamed
      [
        ensureRates(false),
        collectDirs(windowStartMs, settings, retentionCutoffMs, input.awaitRefresh === true),
        attribution._tag === "Some" ? attribution.value.resolve : Effect.succeed(null),
      ],
      { concurrency: 3 },
    );

    const aggregator = new UsageAggregator({
      timeZone: input.timeZone,
      sinceDay: input.sinceDay,
      untilDay: input.untilDay,
      resolution: input.resolution ?? "day",
      ...hourlyWindow,
      rates,
      priceOverrides: createOverrideRateTable(settings.usagePriceOverrides),
      ...(timeline === null ? {} : { attribute: timeline.accountAt }),
      modelAliases: resolveModelAliases(settings.usageModelAliases),
    });

    const sources: UsageSource[] = [];

    // Cleanup may remove transcripts, but the usage we already saved still
    // contributes to its source through the normal aggregation and dedupe path.
    const retainedSinceMs = Math.max(windowStartMs, retentionCutoffMs);
    const filesByDir = scannedDirs.map(({ provider, dir, files }) => {
      const retainedFiles = [...(files ?? [])];
      const livePaths = new Set(retainedFiles.map((file) => file.path));
      for (const [filePath, entry] of fileCache) {
        if (
          entry.provider !== provider ||
          entry.mtimeMs < retainedSinceMs ||
          livePaths.has(filePath) ||
          !isWithinDirectory(filePath, dir)
        )
          continue;
        retainedFiles.push({
          path: filePath,
          records: [...entry.records, ...entry.tailRecords],
          malformedRecords: entry.malformedRecords,
        });
      }
      return retainedFiles;
    });
    const windowEndMs =
      hourlyWindow?.untilTimeMs ??
      Date.parse(`${input.untilDay}T00:00:00Z`) + 86400000 + MTIME_SLACK_MS;
    let resolvedAny = false;
    for (const { reader } of transcriptReaders) {
      if (reader.resolveServiceTiers === undefined) continue;
      const pending = new Set<UsageRecord>();
      for (const [index, files] of filesByDir.entries()) {
        if (scannedDirs[index]?.provider !== reader.provider) continue;
        for (const file of files) {
          for (const raw of file.records) {
            const record = correctedRecord(raw);
            if (
              record.provider === reader.provider &&
              record.unresolvedServiceTierTurnId !== undefined &&
              record.timestampMs >= windowStartMs &&
              record.timestampMs < windowEndMs
            ) {
              pending.add(record);
            }
          }
        }
      }
      if (pending.size === 0) continue;
      const resolved = yield* reader
        .resolveServiceTiers([...pending])
        .pipe(Effect.provideContext(readerContext));
      for (const [record, speed] of resolved) {
        const { unresolvedServiceTierTurnId: _turnId, ...rest } = record;
        resolvedRecords.set(record, { ...rest, speed });
        resolvedAny = true;
      }
    }
    if (resolvedAny) {
      for (const [filePath, entry] of fileCache) {
        const records = correctedBatch(entry.records);
        const tailRecords = correctedBatch(entry.tailRecords);
        if (records === entry.records && tailRecords === entry.tailRecords) continue;
        // Update the current entry by identity; a slow resolver cannot restore an older file.
        fileCache.set(filePath, { ...entry, records, tailRecords });
        cacheDirty = true;
      }
    }
    const crossFileSessions = sharedSessions(filesByDir.flat());

    for (const [
      index,
      { provider, dir, volumeId, files, status, message, action, refreshing, hostId: sourceHostId },
    ] of scannedDirs.entries()) {
      let scannedFiles = 0;
      let skippedFiles = 0;
      let malformedRecords = 0;
      // Distinct per directory. Buckets carry per-cell session counts, but a
      // session spans days and models, so clients total this figure instead.
      const sessionIds = new Set<string>();

      for (const file of filesByDir[index] ?? []) {
        malformedRecords += file.malformedRecords;
        if (file.records.length === 0) {
          skippedFiles += 1;
          continue;
        }
        scannedFiles += 1;
        const eventOccurrences = new Map<string, number>();
        for (const rawRecord of file.records) {
          const record = correctedRecord(rawRecord);
          let usageRecord = record;
          if (
            sharedSessionProviders.has(record.provider) &&
            crossFileSessions.has(record.sessionId)
          ) {
            // Match moved copies without collapsing repeated equal events
            // within one file (timestamps can have only second precision).
            const key = encodeUsageRecordKey([
              record.provider,
              record.sessionId,
              record.timestampMs,
              record.model,
              record.totals,
            ]);
            const occurrence = (eventOccurrences.get(key) ?? 0) + 1;
            eventOccurrences.set(key, occurrence);
            usageRecord = { ...record, dedupeKey: key + ":" + occurrence };
          }
          if (aggregator.add(usageRecord, dir) && record.sessionId.length > 0) {
            sessionIds.add(record.sessionId);
          }
        }
      }

      const sourceMessage =
        message ?? (files === null ? "No transcript directory on this environment." : null);
      sources.push({
        fingerprint: { hostId: sourceHostId ?? hostId, provider, resolvedHomePath: dir, volumeId },
        status:
          files === null && scannedFiles === 0
            ? "missing"
            : malformedRecords > 0
              ? status === undefined || status === "ok"
                ? "partial"
                : status
              : (status ?? "ok"),
        scannedFiles,
        skippedFiles,
        malformedRecords,
        distinctSessions: sessionIds.size,
        message:
          malformedRecords > 0
            ? [
                sourceMessage,
                `${malformedRecords} malformed or inconsistent usage record(s) were skipped; usage may be incomplete.`,
              ]
                .filter(Boolean)
                .join(" ")
            : sourceMessage,
        ...(action ? { action } : {}),
        ...(refreshing ? { refreshing } : {}),
      });
    }

    const pruned = pruneScanCache(fileCache, retentionCutoffMs);
    if (pruned > 0) cacheDirty = true;

    const aggregated = aggregator.finish();
    const readAt = yield* DateTime.now;
    const finishedAtMs = yield* Clock.currentTimeMillis;

    return {
      contractVersion: USAGE_CONTRACT_VERSION,
      readAt: DateTime.formatIso(readAt),
      timeZone: input.timeZone,
      sinceDay: input.sinceDay,
      untilDay: input.untilDay,
      buckets: aggregated.buckets,
      sources,
      pricing: pricing(),
      scanDurationMs: Math.max(0, finishedAtMs - startedAtMs),
      ...(timeline === null || aggregated.attribution === undefined
        ? {}
        : {
            accounts: {
              lines: aggregated.attribution.lines.map((line) => ({
                ...line,
                ...timeline.describe(line.email),
              })),
              unattributed: aggregated.attribution.unattributed,
              notClaude: aggregated.attribution.notClaude,
              switchesInWindow: timeline.switchesAtMs.filter(
                (atMs) => atMs >= windowStartMs + MTIME_SLACK_MS && atMs < windowEndMs,
              ).length,
              basis: timeline.basis,
            },
          }),
    } satisfies UsageSummary;
  });

  const inflightScans = new Map<string, Deferred.Deferred<UsageSummary, UsageReadError>>();

  const scanKey = (input: UsageSummaryInput, settings: ServerSettingsValue): string =>
    JSON.stringify([
      input.timeZone,
      input.sinceDay,
      input.untilDay,
      input.resolution ?? "day",
      input.sinceTime ?? null,
      input.untilTime ?? null,
      settings,
      input.awaitRefresh === true,
    ]);

  const readSummary = Effect.fn("UsageService.readSummary")(function* (input: UsageSummaryInput) {
    const settings = yield* readSettings;
    const key = scanKey(input, settings);
    const deferred = yield* Effect.uninterruptible(
      Effect.gen(function* () {
        const existing = inflightScans.get(key);
        if (existing !== undefined) return existing;

        // Enrollment and detached-fiber creation must be atomic. Otherwise a
        // canceled first caller can leave a Deferred with no scan to finish it.
        const created = Deferred.makeUnsafe<UsageSummary, UsageReadError>();
        inflightScans.set(key, created);
        // Detached so one departing client cannot tear the scan out from under
        // the fibers awaiting it; a finished scan warms the cache either way.
        // The cache write is registered before the waiters resume, so they
        // can await it, but its fiber starts after they have the summary.
        yield* scanSummary(input, settings).pipe(
          Effect.onExit((exit) =>
            Effect.sync(() => inflightScans.delete(key)).pipe(
              Effect.andThen(Exit.isSuccess(exit) ? schedulePersist : Effect.void),
              Effect.andThen(Deferred.done(created, exit)),
            ),
          ),
          Effect.forkDetach,
        );
        return created;
      }),
    );
    return yield* Deferred.await(deferred);
  });

<<<<<<< HEAD
  const readStatsTranscripts = Effect.fn("UsageService.readStatsTranscripts")(function* (
    input: StatsRequest,
  ) {
    const window = yield* Effect.try({
      try: () => statsWindow(input),
      catch: (cause) =>
        new UsageReadError({
          reason: "invalidWindow",
          detail: "Stats requires a valid reporting date and timezone.",
          cause,
        }),
    });
    const settings = yield* readSettings;
    yield* ensureScanCacheLoaded;
    yield* ensureRates(false);
    const overrides = createOverrideRateTable(settings.usagePriceOverrides);
    const hostId = NodeOS.hostname();
    const since = window.previousFrom;
    const historyFrom = shiftStatsDay(input.today, -800);
    const toDay = statsDayFormatter(input.timeZone);
    const activeDays = new Set<string>();
    const cutoff = Date.parse(historyFrom + "T00:00:00Z") - MTIME_SLACK_MS;
    const retentionCutoffMs =
      (yield* Clock.currentTimeMillis) - CACHE_RETENTION_DAYS * 24 * 60 * 60 * 1000;
    const dirs = yield* collectDirs(cutoff, settings, retentionCutoffMs, false, true);
    const sessions: StatsSession[] = [];
    const sources: UsageSource[] = [];
    const cwds = new Set<string>();
    const seenUsage = new Set<string>();
    const sessionFileId = (filePath: string, entry: CachedFile) => {
      const fileId = path
        .basename(filePath, ".jsonl")
        .match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i)?.[0];
      const source = dirs.find(
        (d) => d.provider === entry.provider && isWithinDirectory(filePath, d.dir),
      );
      const rawId =
        entry.activity?.sessionId ||
        entry.records.find((r) => r.sessionId)?.sessionId ||
        fileId ||
        NodeCrypto.createHash("sha256")
          .update(encodeUsageRecordKey([hostId, source?.volumeId, filePath]))
          .digest("hex");
      return (
        entry.provider +
        ":" +
        rawId +
        (entry.activity?.subagent ? ":" + path.basename(filePath) : "")
      );
    };
    // Copying a file changes mtime, not the age of its history.
    const recency = new Map<string, number>();
    for (const [filePath, entry] of fileCache) {
      let last = 0;
      for (const event of entry.activity?.events ?? []) last = Math.max(last, event.at);
      for (const record of entry.records) last = Math.max(last, record.timestampMs);
      for (const record of entry.tailRecords) last = Math.max(last, record.timestampMs);
      recency.set(filePath, last);
    }
    const summaryKey = encodeUsageRecordKey([
      input.timeZone,
      window,
      pricing(),
      settings.usagePriceOverrides,
    ]);
    const owners = new Map<string, string>();
    for (const [filePath, entry] of fileCache) {
      if (
        entry.mtimeMs < cutoff ||
        !dirs.some((d) => d.provider === entry.provider && isWithinDirectory(filePath, d.dir))
      )
        continue;
      const id = sessionFileId(filePath, entry),
        old = owners.get(id);
      if (
        old === undefined ||
        recency.get(filePath)! > recency.get(old)! ||
        (recency.get(filePath) === recency.get(old) && entry.size > fileCache.get(old)!.size)
      )
        owners.set(id, filePath);
    }
    for (const source of dirs) {
      const fingerprint = {
        hostId,
        provider: source.provider,
        resolvedHomePath: source.dir,
        volumeId: source.volumeId,
      };
      const sourceId = NodeCrypto.createHash("sha256")
        .update(encodeUsageRecordKey(fingerprint))
        .digest("hex");
      let scannedFiles = 0,
        skippedFiles = source.failedFiles ?? 0;
      const sessionIds = new Set<string>();
      for (const [filePath, entry] of fileCache) {
        if (
          entry.provider !== source.provider ||
          !isWithinDirectory(filePath, source.dir) ||
          entry.mtimeMs < cutoff
        )
          continue;
        if (!entry.activity) skippedFiles++;
        scannedFiles++;
        if (entry.activity?.cwd) cwds.add(entry.activity.cwd);
        const id = sessionFileId(filePath, entry);
        if (owners.get(id) !== filePath) continue;
        if (entry.activity && !entry.activity.subagent)
          for (const event of entry.activity.events) {
            if (event.kind !== "human" && event.kind !== "phone") continue;
            const day = toDay(event.at);
            if (day >= historyFrom && day <= input.today) activeDays.add(day);
          }
        const records = [...entry.records, ...entry.tailRecords].filter((record) => {
          if (record.dedupeKey === null) return true;
          const key = source.provider + ":" + record.dedupeKey;
          if (seenUsage.has(key)) return false;
          seenUsage.add(key);
          return true;
        });
        const memo = statsSessions.get(filePath);
        const key = summaryKey + sourceId;
        const session =
          memo?.entry === entry &&
          memo.key === key &&
          memo.records.length === records.length &&
          memo.records.every((record, i) => record === records[i])
            ? memo.session
            : summarizeStatsSession({
                id,
                sourceId,
                updatedAt: recency.get(filePath) ?? entry.mtimeMs,
                activity: entry.activity ?? emptyTranscriptActivity(),
                records,
                provider: source.provider,
                timeZone: input.timeZone,
                sinceDay: since,
                untilDay: window.to,
                rates,
                overrides,
              });
        statsSessions.set(filePath, { entry, key, records, session });
        if (session.days.length > 0) {
          sessions.push(session);
          sessionIds.add(id);
        }
      }
      sources.push({
        fingerprint,
        status:
          source.files === null && scannedFiles === 0 ? "missing" : skippedFiles ? "partial" : "ok",
        scannedFiles,
        skippedFiles,
        malformedRecords: 0,
        distinctSessions: sessionIds.size,
        message: skippedFiles
          ? "Some transcripts could not report activity. Available saved usage is included."
          : source.files === null
            ? "No transcript directory on this environment."
            : null,
      });
    }
    if (pruneScanCache(fileCache, retentionCutoffMs) > 0) cacheDirty = true;
    for (const filePath of statsSessions.keys())
      if (!fileCache.has(filePath)) statsSessions.delete(filePath);
    yield* schedulePersist;
    return {
      window,
      hostId,
      since,
      historyFrom,
      toDay,
      activeDays,
      cwds,
      sources,
      sessions,
      pricing: pricing(),
    };
  });

  const readStats = Effect.fn("UsageService.readStats")(function* (input: StatsRequest) {
    const {
      window,
      hostId,
      since,
      historyFrom,
      toDay,
      activeDays,
      cwds,
      sources,
      sessions,
      pricing: snapshotPricing,
    } = yield* readStatsTranscripts(input);
    const scannedRepositories = scanRepositories
      ? yield* scanRepositories([...cwds], shiftStatsDay(historyFrom, -2), hostId)
      : [];
    for (const repo of scannedRepositories)
      for (const commit of repo.commits) {
        const day = toDay(commit.at);
        if (day >= historyFrom && day <= input.today) activeDays.add(day);
      }
    const repositories = scannedRepositories.map((repo) => ({
      ...repo,
      commits: repo.commits.filter((c) => toDay(c.at) >= since && toDay(c.at) <= window.to),
      pullRequests: repo.pullRequests.filter(
        (pr) =>
          (toDay(pr.openedAt) >= since && toDay(pr.openedAt) <= window.to) ||
          (pr.mergedAt !== null && toDay(pr.mergedAt) >= since && toDay(pr.mergedAt) <= window.to),
      ),
    }));
    const unavailable = [
      "Account switches, limit stops, revivals, ignites and resumes require the native Infinitus history.",
      "Cursor, OpenCode and Antigravity do not provide Stats transcript metrics.",
    ];
    if (sources.some((s) => s.fingerprint.provider === "grok" && s.scannedFiles > 0))
      unavailable.push("Grok provides token and cost totals; detailed activity is unavailable.");
    if (!scanRepositories || repositories.some((r) => !r.complete))
      unavailable.push("Repository history is incomplete or unavailable.");
    if (repositories.some((r) => !r.pullRequestsAvailable))
      unavailable.push(
        "Pull-request history is incomplete or unavailable; sign in to gh on the affected environment.",
      );
    return {
      contractVersion: 1,
      readAt: DateTime.formatIso(yield* DateTime.now),
      timeZone: input.timeZone,
      ...window,
      historyFrom,
      activeDays: [...activeDays].sort(),
      sources,
      sessions,
      repositories,
      pricing: snapshotPricing,
      unavailable,
    } satisfies StatsSnapshot;
  });

  const statsScans = new Map<string, Deferred.Deferred<StatsSnapshot, UsageReadError>>();
  const readSharedStats = Effect.fn("UsageService.readSharedStats")(function* (
    input: StatsRequest,
  ) {
    const settings = yield* readSettings;
    const key = encodeUsageRecordKey([
      input,
      settings.usagePriceOverrides,
      settings.usageModelAliases,
      settings.providerInstances,
    ]);
    const deferred = yield* Effect.uninterruptible(
      Effect.gen(function* () {
        const existing = statsScans.get(key);
        if (existing) return existing;
        const created = Deferred.makeUnsafe<StatsSnapshot, UsageReadError>();
        statsScans.set(key, created);
        yield* readStats(input).pipe(
          Effect.onExit((exit) =>
            Effect.sync(() => statsScans.delete(key)).pipe(
              Effect.andThen(Deferred.done(created, exit)),
            ),
          ),
          Effect.forkDetach,
        );
        return created;
      }),
    );
    return yield* Deferred.await(deferred);
  });

  /**
   * Fork (#834): the transcripts are found by file name under every Claude
   * account's projects tree the summary scan walks (one walk each, for every
   * id asked), parsed through the same per-file cache it keeps, so the usage
   * page's next scan is warmer for it. Only the wanted files are parsed.
   */
  const readSessionUsage = Effect.fn("UsageService.readSessionUsage")(function* (input: {
    readonly sessionIds: ReadonlyArray<string>;
  }) {
    const wanted = new Set(input.sessionIds.filter((id) => SESSION_ID.test(id)));
    const found = new Map<string, SessionUsage>();
    if (wanted.size === 0) return found;
    const settings = yield* readSettings;
    const retentionCutoffMs =
      (yield* Clock.currentTimeMillis) - CACHE_RETENTION_DAYS * 24 * 60 * 60 * 1000;
    const dirs = yield* resolveTranscriptDirs(settings, retentionCutoffMs).pipe(
      Effect.provideContext(readerContext),
    );
    const claudeDirs: TranscriptSource[] = [];
    for (const source of dirs) {
      if (source.provider !== "claude") continue;
      const exists = yield* fileSystem
        .exists(source.dir)
        .pipe(Effect.catchCause(() => Effect.succeed(false)));
      if (exists) claudeDirs.push(source);
    }
    if (claudeDirs.length === 0) return found;
    yield* ensureScanCacheLoaded;
    yield* ensureRates(false);
    const overrides = createOverrideRateTable(settings.usagePriceOverrides);
    const bySession = new Map<string, UsageRecord[]>();
    for (const { dir, format } of claudeDirs) {
      const { files } = yield* Effect.promise(() => listTranscriptFiles(dir, 0));
      for (const file of files) {
        const sessionId = path.basename(file.path, ".jsonl");
        if (!wanted.has(sessionId)) continue;
        const { records, update } = yield* readFileRecords(
          file.path,
          file.size,
          file.mtimeMs,
          "claude",
          format,
        );
        if (update !== undefined) {
          const current = fileCache.get(file.path);
          if (
            current === update.replaces ||
            current === undefined ||
            !isLaterRead(current, update.entry)
          ) {
            fileCache.set(file.path, update.entry);
            cacheDirty = true;
          }
        }
        bySession.set(sessionId, [...(bySession.get(sessionId) ?? []), ...records]);
      }
    }
    yield* schedulePersist;
    for (const [sessionId, records] of bySession) {
      const session = foldSessionUsage(records, rates, overrides);
      if (session !== null) found.set(sessionId, session);
    }
    return found;
  });

  // `awaitPersisted` is outside the service interface: tests use it to restart
  // against what a previous instance wrote.
  return {
    readSummary,
    refreshRates,
    awaitPersisted,
    readStats: readSharedStats,
    readSessionUsage,
  } as const;
=======
  return { readSummary, refreshRates, awaitPersisted } as const;
>>>>>>> upstream-sync-43879d970-upstream-renamed
});

export const layer = Layer.effect(UsageService, make).pipe(Layer.provide(ProcessRunner.layer));
