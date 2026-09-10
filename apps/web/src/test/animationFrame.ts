// Vitest setup: Node has no requestAnimationFrame/cancelAnimationFrame. Tests
// that stub them with vi.stubGlobal and then vi.unstubAllGlobals() restore
// the *original* value — undefined on Node — while a worker pool's deferred
// broadcast may still be pending, and the suite dies with
// "cancelAnimationFrame is not defined" (seen on slower GitHub-hosted runners
// in fileEditorLanguageReadiness.test.ts). Giving both a default here means
// an unstub restores a working function instead of nothing. Fork-only file.
if (typeof globalThis.requestAnimationFrame !== "function") {
  globalThis.requestAnimationFrame = (callback: FrameRequestCallback) =>
    setImmediate(() => callback(0)) as unknown as number;
}
if (typeof globalThis.cancelAnimationFrame !== "function") {
  globalThis.cancelAnimationFrame = (handle: number) =>
    clearImmediate(handle as unknown as NodeJS.Immediate);
}
