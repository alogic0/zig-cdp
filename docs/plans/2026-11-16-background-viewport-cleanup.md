# Background viewport cleanup on a fully background Chrome window

Task 2714's responsive check exposed this on Chrome 157.0.8103.38 with
zig-cdp 0.5.0 (de0daae), using the normal desktop browser through an explicit
loopback endpoint and a never-activated disposable blank tab.

Reproducer: record innerWidth/innerHeight (1673x816), run screenshot with
--viewport --emulate-viewport 375x812, then read the dimensions again.
The screenshot is written, but the command exits 1 with
ViewportCleanupIncomplete and the page remains 1x1. Reload restores the native
1673x816 size. This reproduced on both an application page and a blank page.

The cleanup frame capture requested a 1x1 clip after clearing device metrics.
That capture could resize the surface and outlive the bounded cleanup deadline.
Unconditionally capturing an unclipped frame also stalled on the actual desktop,
while removing the flush left geometry stale in the headed fixture.

The final change saves pre-emulation dimensions, briefly enables page-local
focus emulation, clears metrics, and waits up to 100 ms for native geometry.
Only a stale view needs an unclipped capture (`fromSurface: false`). Cleanup
keeps its existing 500 ms uncancelled budget. Input warm-up also uses an
unclipped viewport frame so a timeout cannot leave a 1x1 surface. No user
tab/window activation or native window resize is part of these operations.

Chromium source inspected during diagnosis:
- https://github.com/chromium/chromium/blob/main/content/browser/devtools/protocol/page_handler.cc
- https://github.com/chromium/chromium/blob/main/content/browser/devtools/protocol/emulation_handler.cc
CaptureScreenshot/ScreenshotCaptured temporarily change and restore view size;
surface capture can stall when a fully hidden surface is not presented.

Qualification completed with Zig 0.17.0, Debug and ReleaseSafe:
- `zig build test check example`: 17 library/observer tests passed; example passed.
- `zig build test-headed`: geometry-only, viewport/full screenshots and input
  restore dimensions/DPR; native bounds and the foreground page's focus remain.
  Screenshot-only temporary focus is cleared. Subsequent native resizing works.
- `zig build test-cli -- --case agent` and `--case input`: passed in both profiles,
  including headless/endpoint sequences, errors, timeout, interruption and closure.
- Actual desktop: viewport/full captures, normal sequences and an intentional
  JavaScript error restore 1673x816 after 375x812 emulation in both profiles.
- Actual local CRM tab: ReleaseSafe viewport capture and native restoration pass.
- Format and diff checks pass; the installed binary is ReleaseSafe 0.5.1.

Limits: Openbox is unavailable; no separate test-focus run. Full resource/package
sweeps were not repeated. A short-budget background input warm-up still timed
out and reported incomplete transport cleanup; dimensions remained native.
Actual input can change document focus, so the input case asserts foreground
page/window preservation, not that the clicked background document stays blurred.

Builds used a private ZIG_GLOBAL_CACHE_DIR because the default cached build
runner referenced a missing maker executable. No shared cache was deleted.
