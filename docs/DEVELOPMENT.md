# EasyMacOS 开发与使用说明

A native, local-only clipboard history and screenshot app for **Apple Silicon · macOS 15+**. Built with SwiftUI, AppKit, and the system SQLite library. No third-party runtime dependencies, cloud sync, analytics, or automatic updater.

## Build and run

Install Apple Command Line Tools (`xcode-select --install`) or select a full Xcode installation. Swift 6 or later is required. From this repository:

```sh
./scripts/test.sh
./scripts/build.sh
open dist/EasyMacOS.app
```

The app lives in the menu bar and does not appear in the Dock. Start with the welcome window, then copy new text or images in another app. Click the menu bar icon or press **⌘⇧V**. The initial clipboard is not imported.

- Type to search text and application names; filter by kind, favorites, or source application.
- Use ↑/↓ and Enter, click a row, or use its return button to paste.
- Right-click a row for **Copy only**, full content, favorites, and deletion.
- Escape returns from a preview or closes the panel.
- Right-click the menu bar icon, or use the panel's `…` button, for pause, clear, settings, and quit.
- Change the shortcut in Settings. A shortcut requires Command, Control, or Option; collisions preserve the previous registration.
- The interface follows the system language (Simplified Chinese / English) and appearance.

`dist/EasyMacOS.app` is **ad-hoc signed for local use**. It is not Developer ID signed or notarized and is not a public-release artifact. Move the final, consistently signed app to `/Applications` before enabling launch at login. Rebuilding/re-signing can require macOS privacy permissions to be granted again.

### Command Line Tools compatibility

The build script selects SwiftPM's native build engine because the current CLT 27 default engine can emit dynamic package frameworks unsuitable for copying a lone executable. Native SwiftPM statically links the core target. The script also uses the existing `SwiftUI.State` property wrapper through an explicit type alias, avoiding the CLT 27 SDK's missing SwiftUI state macro plugin. `scripts/test.sh` loads the installed TestingMacros plugin explicitly when available. Tests use Swift Testing; with older toolchains where this is not bundled in CLT, select full Xcode.

## Screenshots and pinned images

Press **⌃⌥A** or choose **Screenshot** from the menu bar's right-click menu. Both screenshot and history shortcuts can be customized independently in Settings. Conflicting registrations keep the previous shortcut.

- Drag on any display to select a region; each capture stays within its starting display. The screenshot freezes before selection and excludes EasyMacOS windows, existing pinned images, and the pointer.
- Adjust the selection using its edges/corners or drag inside it with the selection tool. Annotation locks the selection; **Reselect** clears annotations and starts over.
- Annotate with rectangle, ellipse, arrow, pen, text (including Chinese input), and mosaic. Choose color/width, and use **⌘Z / ⇧⌘Z** to undo/redo. Finish text editing by clicking a tool or output action. Mosaic changes the exported pixels; exported images contain flattened annotations.
- **Copy** (⌘C outside text editing) writes a full-resolution PNG and closes capture. It does not send a paste keystroke. **Save** (⌘S) opens a PNG save dialog with a timestamped filename; canceling returns to editing. **Pin** opens a temporary floating image. **Esc** or a right-click anywhere in the screenshot overlay cancels capture (while entering Chinese text, Escape can first cancel the active composition).
- 钉图使用无标题栏窗口，不显示顶部系统按钮；双击关闭当前钉图。
- Drag pinned images to move them, resize their edges proportionally, and right-click for Copy, Save, Original size, or Close. Multiple pinned images can be open at once, including in fullscreen Spaces. Use **Close all pinned screenshots** in the menu bar to dismiss them together. Pins stay in memory and are not restored after quitting.

Only copying a screenshot or pinned image can add it to history. Recording must be enabled, onboarding complete, and clipboard access allowed; the application exclusion list also applies. Source application is a best-effort observation of the foreground app at capture start. Saving or pinning alone does not add history. A successful copy stays on the clipboard even if history storage fails; a separate notice reports that failure. The existing **20 MiB / 40 million pixel** history image limits do not change screenshot export quality. Larger images can be copied/saved/pinned but are skipped by history with a notice.

Screen capture has a separate working-memory guard (100 million pixels across captured displays and per exported bitmap). Capture buffers and annotation previews are released when a session ends; preview/export rendering is serialized off the main actor. Protected content may be blank according to macOS rules. Display-configuration changes cancel an active session; start another capture after the displays settle.

Window snapping, scrolling screenshots, cross-display selections, OCR, recording video, editing flattened pins, and persistent pin recovery are not included.

## Permissions

Three independent permissions are used:

1. **Clipboard access:** On macOS 15.4+, allow EasyMacOS in System Settings → Privacy & Security → Paste from Other Apps, choosing **Always Allow**. Use the app's permission button to initiate the first user-requested read. Background monitoring waits while access is Ask/Denied and does not repeatedly prompt. If the deep link is unavailable on a macOS release, navigate to that settings page manually. macOS 15.0–15.3 use the existing pasteboard access behavior.
2. **Accessibility:** Optional, for sending ⌘V to the previous app. EasyMacOS checks the system keyboard-event-posting permission and the foreground application immediately before sending events to that process. It cooperatively yields activation to the recipient and waits for stable focus and released modifier keys. If permission or the destination is unavailable, the selected item remains on the clipboard and the app asks you to paste manually. The app cannot verify whether the receiving application actually inserted the content or supports image paste.

3. **Screen Recording:** Optional, used only after explicitly starting a screenshot. Allow EasyMacOS in System Settings → Privacy & Security → Screen & System Audio Recording (wording varies by macOS version). The first permission request ends that screenshot attempt; invoke the shortcut again after granting access. If macOS requests a restart, quit and reopen EasyMacOS. Settings shows the current permission status and an authorization button. No screen recording permission is requested on launch, during history recording, or by the automated tests.

Launch at login is off by default. The switch uses `SMAppService` and can require approval in System Settings → General → Login Items. No Apple Events automation or input monitoring permission is requested. Screenshot capture does not record audio or video.

If System Settings shows EasyMacOS enabled but Automatic Paste still reports permission needed, a local rebuild may have invalidated the old authorization: ad-hoc builds have a content-hash signing identity. Remove only the old EasyMacOS entry in Accessibility / Device Control and Data Access, use **Show current EasyMacOS in Finder** to locate the exact running app, add that app again, enable it, and quit/reopen EasyMacOS. The status checks actual event-posting access; it never assumes the system toggle grants the current binary access. Public releases must use a stable Developer ID identity to avoid this local-build identity change.

To diagnose the app's own permissions without prompting or reading clipboard content:

```sh
open -n --stdout /tmp/pasteman-permission-status.txt dist/EasyMacOS.app --args --permission-status
cat /tmp/pasteman-permission-status.txt
```

The diagnostic instance prints its application path and actual Accessibility / keyboard-event authorization, then exits without starting history recording. A terminal's own permission check is not a substitute for the app's identity check.

## Storage and privacy

History is in `~/Library/Application Support/PasteMan/`:

- `history.sqlite` plus SQLite WAL/SHM files: metadata and full plain text.
- `Images/`: normalized PNG images and thumbnails.
- Preferences: the app's UserDefaults domain (default bundle ID `app.pasteman.PasteMan`).

Ordinary history defaults to **500 entries / 30 days** (either limit applies). Favorites sort first and remain until deleted. A **512 MiB logical content budget** includes UTF-8 text bytes, normalized image bytes, and thumbnail bytes; SQLite overhead, filesystem allocation, and WAL can make actual disk use higher. Ordinary items are evicted oldest first. Favorites are never automatically removed; if they leave insufficient room for an incoming item, that copy is skipped with a visible message. Recording resumes for future copies after space is freed. Cleanup runs at startup, on captures/settings changes, and every minute. Clear history keeps favorites unless explicitly selected otherwise.

Identical content updates its existing item's timestamp and source, preserving its ID and favorite status. Source is a best-effort observation of the frontmost application when the 500 ms poll detects a copy, not an authoritative pasteboard author. Very rapid copies between polls may be missed. Pausing/resuming establishes a fresh baseline and does not backfill copies from the pause. Images being prepared when pausing or clearing are invalidated.

Normal recording polls every 500 ms. Paused/onboarding sessions stop routine clipboard checks and wake for cleanup every minute. When clipboard permission is unavailable, checks back off to five seconds; detecting restored permission establishes a fresh baseline before recording new copies. Resuming or finishing onboarding immediately reschedules normal polling.

The first supported item in a clipboard change is stored; image data takes precedence over text in that item. Finder file references are skipped. Text formatting is not retained. Common bitmap formats accepted by ImageIO are normalized to PNG, first frame only, stripping source metadata. Inputs above **20 MiB / 40 million pixels**, invalid images, and unsupported formats are skipped. Animated image playback, OCR, files, rich text, and cloud sync are outside v1.

Sensitive/transient/autogenerated pasteboard markers and common password-manager bundle IDs are filtered before reading payloads. You can edit exclusions by bundle ID or choose an installed app. This is best-effort protection: unmarked passwords can still be captured. Pause before copying secrets. Local history is **not additionally encrypted**; account permissions and FileVault provide system-level protection. Deleted database content is compacted on explicit clear, without a secure-erasure guarantee on APFS/SSDs. Clipboard payloads are never logged.

## Packaging and public release

Create a local DMG after building:

```sh
./scripts/dmg.sh
```

For an actual public release, use a **Developer ID Application** certificate and a `notarytool` keychain profile. Do not put credentials in the repository. Configure the keychain using Apple's `notarytool store-credentials` flow, then:

```sh
export DEVELOPER_ID_APPLICATION='Developer ID Application: Your Name (TEAMID)'
export NOTARY_PROFILE='EasyMacOS-Notary'
# Choose a reverse-DNS bundle ID owned by the publisher before the first public release.
export BUNDLE_ID='com.yourcompany.EasyMacOS'
export VERSION='1.0.0'
./scripts/release.sh
```

The release script builds arm64, enables Hardened Runtime with no sandbox entitlement, verifies signatures, notarizes/staples the app, creates/signs/notarizes/staples the DMG, and runs Gatekeeper assessment. The release process stops on failure. Credentialed signing/notarization have not been performed for the local build. Updates are manual replacement via a newly downloaded app. Keep the bundle ID and signing identity stable between releases to preserve preferences/permissions.

## Architecture

- `PasteManCore`: actor-isolated SQLite repository, content hashing, bounded ImageIO processing, capture count gate, and privacy rules. SQL binds clipboard strings as parameters; identifiers and files use generated UUIDs. Read queries check cancellation between rows and inside SQLite's VM, so obsolete searches release the repository promptly. Retention and admission share one compact metadata snapshot per save; no-op cleanup avoids a write transaction.
- `PasteMan` (app target): observable model, injectable clipboard/permission/paste services, independent Carbon global hotkeys, ScreenCaptureKit still capture, Core Graphics/Core Text annotation rendering, AppKit status item/floating panel/window lifecycle, SwiftUI history/settings/onboarding. Source filters are refreshed on history changes, rather than every search. Long text uses a selectable, read-only AppKit text view with noncontiguous layout. Image conversion and display decoding run off the main actor. Display previews are downsampled to the view size and screen scale; one actor serializes display decoding. Canceled queued requests are skipped, in-flight synchronous results are discarded if canceled, and autoreleased decoder objects are drained after each operation. Original saved images and pasted image quality are unchanged. Closing the history panel cancels its queries and image tasks and releases its views; decoded thumbnails have a separate 8 MiB LRU cache, purged on memory pressure or clear and invalidated on deletion. Full-size previews are not cached.
- `Tests`: temporary stores, controllable clocks, synthetic images, isolated UserDefaults and named pasteboards. Tests never read/write the general clipboard or request privacy permissions.

## Validation

```sh
./scripts/test.sh
# Optional offscreen native view rendering (does not show windows):
PASTEMAN_RENDER_TESTS=1 ./scripts/test.sh
# PNG output defaults to /tmp/pasteman-rendering
# Real menu-bar regression check against one running, onboarded instance:
swift scripts/ui-smoke.swift
# Interactive cross-process event-delivery check with a disposable synthetic input:
PASTEMAN_PASTE_TESTS=1 ./scripts/test.sh
```

The interactive paste test creates a disposable recipient app and verifies that the production paste executor restores it after dismissing the history panel and delivers Cmd-V to its input. Its synthetic receiver does not read the clipboard. It requires existing event-posting permission for the test runner and temporarily changes window focus.

The UI smoke check requires existing Accessibility access for the invoking terminal. It clicks the app's status item three times, verifies the history stays onscreen and receives keyboard focus, and closes it with Escape each time. It does not read clipboard content or grant permissions. The history uses a nonactivating panel so status-item clicks do not depend on successful app activation.

Screenshot tests use synthetic screen images and injected capture/presentation/save boundaries without capturing real screens or showing windows. They cover crop direction, negative screen origins, 1×/2× coordinates, orientation, flattened drawing and mosaic pixels, undo/redo, selection movement/resize/locking, capture cancellation and reentry, copy failure, save cancellation/failure, explicit-history deduplication/privacy, and independent shortcuts. Offscreen rendering includes light/dark screenshot toolbars.

Automated coverage includes persistence/reopening, exact text (Unicode/newlines/NUL), literal search beyond previews, deduplication, favorite sorting, count/age/byte-budget eviction, clear-with-favorites, image alpha and bounded thumbnails, missing image recovery, display downsampling, serialized decoding and cancellation, orphan cleanup, privacy exclusions, denied permissions, pause/self-write baselines, pending-image cancellation, multi-item/image precedence and settings persistence. Rendering checks cover light/dark history, settings, and onboarding.

Performance regression coverage includes cancellation before SQLite returns its first row and connection reuse afterward, thumbnail byte-budget eviction and invalidation, full-text preview preservation, source filters across hidden changes, and permission/pause recovery baselines. Optional rendering also covers a 10,000-line synthetic text preview.

Before public release, run the manual matrix in 本机验收清单. Real cross-app input delivery, permissions dialogs, login item approval, multiple displays, older macOS 15 runtime compatibility, and long-running memory behavior require interactive testing; passing unit tests does not establish those results.

## 版本来源与核对

应用版本统一来自 `scripts/Info.plist` 的 `CFBundleShortVersionString`，构建号来自 `CFBundleVersion`。每轮修改仅递增一次修订版本和构建号，变更写入项目根目录的版本记录。

打包后，菜单栏菜单、图标提示和设置页直接读取应用包中的实际版本。命令行运行未打包的程序时显示“开发构建”，避免误报发布版本。

无需启动剪贴板监控即可核对应用版本：

```sh
dist/EasyMacOS.app/Contents/MacOS/EasyMacOS --version
```
