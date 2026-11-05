# EasyMacOS 开发与使用说明

A native, local-only clipboard history and screenshot app for **Apple Silicon · macOS 15+**. Built with SwiftUI, AppKit, and the system SQLite library. No third-party runtime dependencies, cloud sync, analytics, or automatic updater.

## Build and run

Install Apple Command Line Tools (`xcode-select --install`) or select a full Xcode installation. Swift 6 or later is required. From this repository:

```sh
./scripts/test.sh
# 首次在本机配置固定代码签名证书；后续无需重复创建
./scripts/setup-signing.sh
./scripts/build.sh
open dist/EasyMacOS.app
```

同一次构建只生成 `dist/EasyMacOS.app`。访达右键扩展以 `FinderExtension.appex` 内嵌在同一个应用包中，版本统一从 `scripts/Info.plist` 注入。

The app lives in the menu bar and does not appear in the Dock. Start with the welcome window, then copy new text or images in another app. Click the menu bar icon or press **⌘⇧V**. The initial clipboard is not imported.

- Type to search text and application names; filter by kind, favorites, or source application.
- Use ↑/↓ and Enter, click a row, or use its return button to paste.
- Right-click a row for **Copy only**, full content, favorites, and deletion.
- Escape returns from a preview or closes the panel.
- Right-click the menu bar icon, or use the panel's `…` button, for pause, clear, settings, and quit.
- Change the shortcut in Settings. A shortcut requires Command, Control, or Option; collisions preserve the previous registration.
- The interface follows the system language (Simplified Chinese / English) and appearance.

本地构建使用**固定的代码签名证书**，不再使用临时签名。`scripts/setup-signing.sh` 首次创建有效期十年的本地自签名证书，私钥以不可导出的方式保存在当前用户默认钥匙串中，只允许系统签名工具访问；仅在当前用户域信任其代码签名用途，不授予网站证书信任。签名身份指纹保存在 `~/Library/Application Support/EasyMacOS/Signing/identity.sha1`，不进入仓库。重复运行初始化脚本复用原身份，不创建替代证书；原证书不可用时停止并提示恢复。

构建默认读取本机配置，也可用 `SIGNING_IDENTITY` 指定钥匙串中的固定证书身份；正式发布可用 `DEVELOPER_ID_APPLICATION`。缺少有效身份时构建失败，不回退到临时签名。首次由临时签名迁移到固定证书后，需要为新身份授权一次；之后保持同一证书、应用标识和运行路径时，指定要求不随构建内容变化，通常可保留隐私授权。授权刚开启后若进程仍使用旧状态，退出再打开应用。更换证书、迁移路径、重置系统隐私数据库或系统策略变化仍可能要求重新授权。

本地自签名只解决本机开发的身份稳定性，不等于苹果开发者签名或公证，不作为公开发布产物。启用开机启动前，先确定最终运行路径；如果使用 `/Applications`，请先复制再完成一次授权，后续覆盖同一路径。证书与私钥须长期保留在钥匙串中，不能随构建清理或重新生成。

验证内容变化后仍匹配相同签名身份（只操作临时副本，不修改隐私授权）：

```sh
./scripts/check-signing.sh
codesign -d -r- dist/EasyMacOS.app
```

### Command Line Tools compatibility

The build script selects SwiftPM's native build engine because the current CLT 27 default engine can emit dynamic package frameworks unsuitable for copying a lone executable. Native SwiftPM statically links the core target. The script also uses the existing `SwiftUI.State` property wrapper through an explicit type alias, avoiding the CLT 27 SDK's missing SwiftUI state macro plugin. `scripts/test.sh` loads the installed TestingMacros plugin explicitly when available. Tests use Swift Testing; with older toolchains where this is not bundled in CLT, select full Xcode.

## Screenshots and pinned images

Press **⌃⌥A** or choose **Screenshot** from the menu bar's right-click menu. Both screenshot and history shortcuts can be customized independently in Settings. Conflicting registrations keep the previous shortcut.

- Drag on any display to select a region; each capture stays within its starting display. The screenshot freezes before selection and excludes EasyMacOS windows, existing pinned images, and the pointer.
- Adjust the selection using its edges/corners or drag inside it with the selection tool. Annotation locks the selection; **Reselect** clears annotations and starts over.
- Annotate with rectangle, ellipse, arrow, pen, text (including Chinese input), and mosaic. Choose color/width, and use **⌘Z / ⇧⌘Z** to undo/redo. Finish text editing by clicking a tool or output action. Mosaic changes the exported pixels; exported images contain flattened annotations.
- **Copy** (⌘C outside text editing) writes a full-resolution PNG and closes capture. It does not send a paste keystroke. **Save** (⌘S) opens a PNG save dialog with a timestamped filename; canceling returns to editing. **Pin** opens a temporary floating image. **Esc** or a right-click anywhere in the screenshot overlay cancels capture (while entering Chinese text, Escape can first cancel the active composition).
- 钉图使用无标题栏窗口，不显示顶部系统按钮；双击关闭当前钉图。
- 鼠标悬停在钉图上即可使用滚轮或触控板上下滚动缩放，无需先点击；以鼠标所在位置为缩放中心并保持图片比例。显示比例最低为原图的百分之十（同时遵循窗口最小尺寸），最高为原图的八倍；右键菜单可恢复原始显示比例，复制和保存保持原图分辨率。
- 同一钉图保存尚未结束时不重复启动保存；关闭钉图会取消尚在等待的保存面板并释放视图，取消及关闭后的迟到错误不再弹窗。用户已经确认文件目标后，开始的原子写入会完成，关闭钉图不撤销已确认的写入。
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

系统设置显示已开启但应用仍报告无权限时，先退出再打开应用。历史临时签名构建的身份绑定内容哈希，迁移到固定证书时需要移除旧条目，通过“定位当前应用”重新添加并授权一次。之后同一固定证书重新构建不会再依赖内容哈希匹配身份。界面仍检查系统真实权限，不把开关显示当作实际授权。公开发布使用稳定的苹果开发者证书并完成公证。

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

发布脚本构建 `arm64` 版本并启用强化运行时，先签署沙盒访达扩展，再签署 EasyMacOS 宿主应用；随后验证签名、提交公证并附加公证票据，生成包含单个应用的磁盘映像，再为映像签名、公证并进行系统安全评估。任一步骤失败都会停止。当前本机构建尚未执行开发者证书签名与公证；更新通过手动替换应用完成，发布时应保持应用标识和签名身份稳定，以保留偏好设置与权限。

## Architecture

- `FinderMenuCore`：菜单动作、配置文件、结构化操作链接、路径格式化、目录选择与不覆盖创建逻辑。操作链接只接受固定动作和绝对本地路径，终端通过系统文件夹终端服务启动，使用独立剪贴板传参，不拼接执行脚本。
- `PasteMan`：唯一的宿主应用，提供剪贴板历史、截图、钉图、三合一设置页，以及访达操作请求队列。
- `FinderExtension`：内嵌访达扩展，在每次右键时读取配置并生成四项轻量菜单；复制动作直接完成，新建和终端动作通过固定 `easymacos://finder` 请求交给宿主应用。扩展只读取所选项目元数据，不遍历目录、不读取文件内容、不维护文件索引。
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

## 对象释放与内存趋势验证

常规测试包含对象释放回归检查：重复二十一轮历史列表及图片、长文本预览挂载与移除，截图选区、标注及预览取消，复制、保存成功、保存失败、保存取消，以及单张和全部钉图关闭。通过弱引用检查窗口、视图、编辑状态、原始及选区位图、导出图片和最终持有者是否释放；另检查捕获尚未返回时取消及晚到位图释放，十二轮监控任务停止及缓存清理，以及十二组三张独立钉图批量关闭。

```sh
# 只运行对象生命周期检查，默认跳过内存趋势采样
./scripts/test.sh --filter MemoryLifecycleTests
# 在独立测试进程中运行生命周期检查及内存趋势采样
./scripts/memory-check.sh
# 可选：指定本机报告目录
./scripts/memory-check.sh /tmp/easymacos-memory-check
```

趋势验证使用宽一千九百二十、高一千零八十像素的合成截图，先预热十四轮，再运行六批、每批十轮。每轮结束都检查对象释放，分批等待任务与临时对象排空后，通过系统接口读取测试进程的物理内存占用及驻留内存。物理占用首尾增长达到二十四兆字节，或线性拟合斜率达到每轮二百五十六千字节时，检查失败。阈值用于发现明显的累积回归，不能证明不存在小量泄漏。

脚本仅运行串行的内存验证测试组，避免其他测试污染采样；默认在系统临时目录生成环境、版本、日志以及逗号分隔和结构化采样文件。报告及实际性能数据只保留在本机，不提交。测试不读取真实剪贴板、不捕获屏幕、不显示窗口或请求权限；保存和复制使用注入边界。历史界面按应用相同的移除视图和取消查询流程操作，不覆盖真实菜单栏交互。实际截图系统服务、保存对话框、窗口合成器及长时间使用仍需交互验证。

## 版本来源与核对

应用版本统一来自 `scripts/Info.plist` 的 `CFBundleShortVersionString`，构建号来自 `CFBundleVersion`。每轮修改仅递增一次修订版本和构建号，变更写入项目根目录的版本记录。

打包后，菜单栏菜单、图标提示和设置页直接读取应用包中的实际版本。命令行运行未打包的程序时显示“开发构建”，避免误报发布版本。

无需启动剪贴板监控即可核对应用版本：

```sh
dist/EasyMacOS.app/Contents/MacOS/EasyMacOS --version
```

## EasyMacOS 访达右键菜单的安装与启用

```sh
./scripts/build.sh
open dist/EasyMacOS.app
```

### 文件剪切与原生移动

文件选区的右键一级菜单提供“剪切”，支持单选、多选文件和文件夹；空白处和侧边栏不提供剪切。剪切仅将标准文件引用与随机标记写入系统剪贴板，不删除或移动源文件，也不产生额外纯文本路径。文件引用不会保存到剪贴板历史。普通系统粘贴仍是复制，可在目标目录选择“粘贴（移动）”或直接使用访达的 ⌥⌘V。

“粘贴（移动）”只在剪切记录有效时显示，目标判断与新建一致。主应用串行复核随机标记、剪贴板变更编号、文件列表、源项目存在性及目标目录；原目录移动、递归移动和源缺失整批拒绝。源符号链接按链接本身处理。实际移动只向确认在前台且浏览目标目录的访达发送一次原生移动快捷键，不自行覆盖或删除文件。重名冲突、移动进度、跨磁盘操作和撤销由访达处理；冲突取消或移动失败后不自动重试，需要重新剪切。

该功能复用辅助功能权限，不使用自动化脚本授权。新复制使旧剪切记录失效；移动命令提交后应用记录消费，系统剪贴板保留供访达读取。主应用重启后只接受与当前剪贴板完整匹配的记录。正在编辑名称、显示对话框、切换应用、修饰键未释放、目标无法确认或两秒超时时不发送按键。

小型状态存储位于配置目录下 `finder-cut.json`，仅包含标记、文件数、剪贴板计数、消费状态和持久菜单编号，不保存源路径；扩展只读取此文件及剪贴板变更编号。负数菜单标识编码持久剪切编号，旧菜单不能粘贴后来剪切的文件。普通动作使用固定编号，与菜单显示顺序分离，保持已有菜单标识兼容。

```sh
./scripts/test.sh --filter Finder
# 使用已有辅助功能权限的测试进程，真实移动合成文件并验证访达撤销
EASYMACOS_FINDER_MOVE_LIVE=1 ./scripts/test.sh --filter realFinderMovesSyntheticSelectionAndCanUndo
# 使用实际应用和已启用扩展，检查多选剪切、移动、撤销和重名取消
swift scripts/finder-smoke.swift "$PWD/dist/EasyMacOS.app" --move-only
```

真实交互检查只操作临时合成目录，会短暂切换访达窗口并将合成文件引用写入剪贴板，不读取真实历史或已有文件内容。跨卷检查可指定 `EASYMACOS_MOVE_VOLUME` 为系统临时目录下挂载的合成测试卷，脚本只在其中新建独立子目录进行验证。

扩展同时注册系统根目录和各挂载卷根目录，并在卷挂载或卸载时刷新注册范围；仅读取卷列表元数据，不扫描卷中文件。这样新挂载的本地磁盘也能显示剪切与粘贴移动菜单。

将 `EasyMacOS.app` 放入 `/Applications` 后打开设置中的“访达”分类。点击“管理访达扩展…”调用系统访达扩展管理界面；在不同系统版本中，入口通常位于“通用 → 登录项与扩展 → 访达扩展”。启用显示名称为“EasyMacOS Finder Menu”的项目，再返回应用核对状态。应用不会自行更改系统扩展开关。

启用后，在普通本地目录中的文件、文件夹或空白处右键，常用操作直接显示在一级菜单，仅“新建文件”展开文件类型子菜单。新建会在所选文件夹内进行；选择普通文件时使用其所在目录。多选项目只有共同指向同一目录时才允许新建或打开终端，目录不明确时项目会禁用。应用包视作文件，避免在包内创建项目。路径和文件名支持多选逐行复制。新建直接创建零字节的“未命名.后缀”，遇到同名文件、目录或符号链接时依次尝试“未命名 2.后缀”等编号，不覆盖原项目。其他写入错误直接提示。

访达设置支持添加或删除文件类型，默认后缀为 `.txt`、`.json`、`.xml`、`.md`、`.csv`、`.html`、`.css`、`.js`。输入兼容一个前导点、首尾空白和大小写，并按规范化后缀去重；支持 `tar.gz` 等复合后缀，禁止空段、分隔符、冒号、内部空白、控制字符及过长名称。删除全部类型后隐藏新建菜单，恢复默认设置会恢复默认类型与开关，同时保留不复用的类型编号。旧配置缺少类型列表时补入默认类型并保留原开关。

创建后仅定位一次文件，最多等待两秒。已有辅助功能对象读取及键盘事件发送权限，且访达前台、唯一选区为新文件、修饰键已释放时，向该访达进程发送回车，再确认该文件的真实名称编辑框出现。用户切换应用、选区不符、未授权或超时均不向其他项目发送按键；取消重命名保留文件。普通失败显示三秒自动关闭的非激活提示，未授权时显示十秒的权限说明及“开启自动重命名…”按钮。访达设置直接显示此功能的授权状态并提供同一入口，也可复用“权限”分类的入口。只有用户点击授权按钮才请求系统权限，新建流程本身不主动请求权限，也不使用自动化脚本。授权后再次新建即可直接进入访达名称编辑状态。首次从历史临时签名迁移到固定证书，需要重新授权一次。

访达跨进程重建扩展菜单时可能丢失图标模板着色。菜单图标采用两种像素密度的普通透明位图，并保留模板标记，每次生成菜单时根据系统深浅外观解析系统文字语义颜色，避免扩展进程的黑色符号在深色访达菜单中直接显示。外观切换后下次右键生效。

配置写入 `~/Library/Application Support/EasyMacOS/finder-menu.json`，通过原子替换保存，下一次右键读取。关闭配置窗口或退出应用后，系统仍管理右键扩展；需要隐藏菜单时关闭“显示右键菜单”，需要完全停用扩展时使用系统设置。新建与打开终端会按需唤醒同一个 EasyMacOS 应用。

本地构建使用固定证书，同时签署主应用及扩展。访达扩展按系统要求启用沙盒，具有用户所选文件只读权限，以及读取 `~/Library/Application Support/EasyMacOS/` 配置目录的只读例外；扩展不直接创建项目，宿主应用未启用沙盒。公开发布使用现有开发者签名与公证流程，先签扩展、再签 EasyMacOS 宿主应用；发布前核对 EasyMacOS 及扩展标识，并确保扩展标识以宿主标识为前缀。首次迁移签名身份可能需要在系统设置中重新启用扩展。系统保护目录的写入限制仍然生效，失败会显示系统错误。

```sh
# 定向核心与配置回归检查
./scripts/test.sh --filter Finder
# 可选：测试进程已有辅助功能权限时，使用临时合成文件验证真实原地重命名与取消
# 此命令会短暂改变访达焦点，不修改授权
EASYMACOS_FINDER_RENAME_LIVE=1 ./scripts/test.sh --filter realFinderRenameWithExistingRunnerPermission
# 可选：输出明暗两套原生界面截图，目录仅在本机保留
EASYMACOS_FINDER_RENDER_DIR="$PWD/test-results/finder" ./scripts/test.sh --filter FinderModelTests
# 可选：在临时目录验证立即创建、自动编号与取消重命名；需要终端已有辅助功能权限
swift scripts/finder-smoke.swift "$PWD/dist/EasyMacOS.app"
# 当前宿主已授权时，严格核对自动重命名
swift scripts/finder-smoke.swift "$PWD/dist/EasyMacOS.app" --expect-rename
# 当前宿主未授权时，严格核对只创建及短暂提示；脚本不会变更权限
swift scripts/finder-smoke.swift "$PWD/dist/EasyMacOS.app" --expect-fallback
# 扩展启用后：检查一级菜单、类型子菜单、立即新建、自动编号和两项复制
# 该模式会把合成路径及名称写入系统剪贴板
swift scripts/finder-smoke.swift "$PWD/dist/EasyMacOS.app" --context-menu
# 检查文件操作期间主应用没有抢占前台，避免访达与宿主之间来回切换造成闪动
swift scripts/finder-smoke.swift "$PWD/dist/EasyMacOS.app" --context-menu --expect-background
# 独立检查终端操作，两次点击分别只产生一个窗口，并核对合成目录及剪贴板未改变
# 只关闭本次新建、且工作目录与合成目录一致的终端窗口，已有终端保持不动
swift scripts/finder-smoke.swift "$PWD/dist/EasyMacOS.app" --terminal-only
# 核对应用与内嵌扩展
dist/EasyMacOS.app/Contents/MacOS/EasyMacOS --version
codesign --verify --deep --strict dist/EasyMacOS.app
pluginkit -m -A -D -v -i app.pasteman.PasteMan.FinderExtension
```

核心检查使用临时目录，覆盖旧配置迁移、类型增删与去重、空列表、恢复默认时编号不复用、配置保存失败保留原值、特殊字符路径与后缀请求往返、多选复制、目标目录、目录链接与应用包识别、非法后缀、默认与复合后缀的零字节创建、自动编号、并发创建、目录与符号链接保护，以及写入错误。原地重命名通过可替换的系统交互接口覆盖未授权、权限撤回、焦点改变、选区不符、多选、修饰键未释放、两秒超时及请求队列串行等待。界面检查离屏渲染，不读写真实剪贴板。交互脚本仅操作带特殊字符路径的临时目录，验证立即创建、自动编号和原内容保护；观察原地重命名或短暂提示，已进入重命名时取消并核对文件保留。真实菜单模式额外检查菜单层级及两项复制。脚本不会请求或更改权限；未启用扩展、首次授权、终端工作目录和系统保护目录仍需按实际运行环境核对。

访达点击事件从系统后台消息队列调用扩展。回调使用系统保留的菜单 `tag` 解码动作，必须在回调返回前捕获 `targetedURL()` 和 `selectedItemURLs()`，再把值类型请求交给主线程执行。新建菜单的 `tag` 同时编码文件类型持久编号与目标上下文，点击时重新读取配置按编号查找；已删除编号直接拒绝执行，不能根据列表下标解析类型。宿主串行等待创建、定位及重命名完成后再处理下一请求。不要给系统回调入口直接添加主线程隔离，或依赖菜单跨进程重建时不能保留的自定义附带对象。

扩展交给宿主的文件操作使用后台打开配置，不激活或隐藏主应用，也不隐藏其他应用，避免新建时先切换到宿主再切回访达引起闪动。只有打开访达设置时主动激活宿主。真实菜单检查可通过 `--expect-background` 监听主应用激活通知，核对新建及复制期间没有抢占前台焦点。

终端服务只接收独立剪贴板中的一个目录对象，不同时提供纯文本路径，避免系统分别处理两类输入而重复打开窗口。自动检查验证一次菜单点击只产生一个新终端窗口，并从该窗口的目录元数据核对工作目录，不拼接执行终端命令、不读取已有终端内容。

剪贴板监控在前台应用切换时更新检测基线，丢弃切换前尚未检测、无法确认来源的复制；已经捕获且归属确定的图片以及带显式来源的截图继续处理。此策略优先避免错误来源回填，不能保证识别所有后台应用的剪贴板写入。重新复制重复图片时仅检查原图与缩略图是否存在，缺失部分从新复制的数据原子恢复；不重写已有文件，保留记录标识和收藏。
