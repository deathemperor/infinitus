// Vitest setup: Node has no requestAnimationFrame/cancelAnimationFrame. vi.unstubAllGlobals()
// restores the original (undefined) while a worker pool's deferred broadcast may still be pending,
// and the suite dies with "cancelAnimationFrame is not defined". A default here makes an unstub
// restore a working function. Fork-only file.
if (typeof globalThis.requestAnimationFrame !== "function") {
  globalThis.requestAnimationFrame = (callback: FrameRequestCallback) =>
    setImmediate(() => callback(0)) as unknown as number;
}
if (typeof globalThis.cancelAnimationFrame !== "function") {
  globalThis.cancelAnimationFrame = (handle: number) =>
    clearImmediate(handle as unknown as NodeJS.Immediate);
}
