# EasyMacOS 开发与使用说明

## 模块独立开关

- 在“截图”“剪贴板”“右键菜单”设置页顶部使用对应总开关；详细设置在关闭时保留并置灰，鼠标增强继续使用鼠标页原有开关。
- 关闭截图会释放截图快捷键并取消当前截图与未完成导出，已有钉图仍可查看、复制、保存和关闭。
- 关闭剪贴板会释放历史快捷键、收起面板，停止采集、轮询和自动清理；已有历史、收藏、保留策略、排除名单和暂停状态保留。恢复后只记录新复制的内容，不补录关闭期间内容。
- 剪贴板关闭时，截图及钉图仍可复制到系统剪贴板，但不会写入历史。菜单栏左击改为打开应用菜单，始终可进入设置重新开启模块。
- 右键菜单复用现有访达配置，不修改系统扩展授权；关闭后下次打开菜单不显示本应用操作，已生成但尚未开始的菜单请求会被拒绝，正在执行的文件操作正常完成。
- 开关选择重启后保留。重新开启时若快捷键已被其他应用占用，对应设置页会显示提示，可修改快捷键或释放占用后重新开关；其他模块继续运行。
- 历史保留天数与条数上限在设置写入时校验至少为一，修改后由模块控制器重新调度清理，无需打开或保留设置窗口。收藏不受普通历史的时间和数量限制影响；关闭剪贴板时不清理，恢复后应用最新策略。

```sh
./scripts/test.sh --filter ModuleToggleTests
PASTEMAN_RENDER_TESTS=1 ./scripts/test.sh --filter RenderingTests
```

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
- 界面支持简体中文、英文和系统深浅外观。历史记录每页加载一百条，滚动或键盘选择会继续加载；数量后的加号表示仍有后续记录。数据库故障时显示重试入口，截图和访达功能继续可用。

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
- 拖动钉图可移动位置，拖动边缘可等比缩放，右键可复制、保存、恢复原始比例或关闭。钉图支持多窗口和全屏空间，菜单栏可统一关闭全部钉图。原图使用私有临时文件保存，所有钉图共用三十二兆字节的显示缓存，复制和保存保留原始分辨率，压缩编码按需执行。关闭后清理临时原图，退出后不恢复钉图。

Only copying a screenshot or pinned image can add it to history. Recording must be enabled, onboarding complete, and clipboard access allowed; the application exclusion list also applies. Source application is a best-effort observation of the foreground app at capture start. Saving or pinning alone does not add history. A successful copy stays on the clipboard even if history storage fails; a separate notice reports that failure. The existing **20 MiB / 40 million pixel** history image limits do not change screenshot export quality. Larger images can be copied/saved/pinned but are skipped by history with a notice.

Screen capture has a separate working-memory guard (100 million pixels across captured displays and per exported bitmap). Capture buffers and annotation previews are released when a session ends; preview/export rendering is serialized off the main actor. Protected content may be blank according to macOS rules. Display-configuration changes cancel an active session; start another capture after the displays settle.

Window snapping, scrolling screenshots, cross-display selections, OCR, recording video, editing flattened pins, and persistent pin recovery are not included.

## 鼠标滚动增强

在设置的“鼠标”页开启增强，未保存选择时默认关闭，之后恢复已保存的选择。平滑滚动默认开启、反向默认关闭、速度增益为一倍、平滑时长为一百八十毫秒；速度增益可调半倍至十倍，平滑时长可调一百至五百毫秒。反向只翻转鼠标事件，不改系统方向；关闭平滑仍可使用速度与反向。恢复默认会同时关闭增强并清空鼠标排除名单，不改变剪贴板排除名单。

默认只处理离散滚轮。远程桌面可能将实体鼠标滚轮转换为连续像素事件，导致增强开启后仍无效果；可在鼠标页开启“远程滚轮兼容”，同时处理不带手势或惯性阶段的连续事件。兼容选项默认关闭，独立保存在 `remoteCompatibility`，旧偏好缺少字段时保留全部原有选择。

兼容模式仍放行带手势或惯性阶段的触控板事件，不按鼠标型号或输入来源进程猜测设备。某些设备或驱动若同样上报无手势连续事件，也会受到兼容模式影响，切回本机精确滚动或使用其他滚动增强工具时可关闭该选项。命令键或控制键组合滚动、本应用窗口及排除名单中的应用始终直接放行；按事件实际接收进程匹配名单，不以前台应用猜测接收方。未知应用标识不接管。

开启平滑后，所有应用的轻滚与大幅滚动统一使用平滑像素动画，不按网站、浏览器或页面区域切换原生步进。最短步长范围为 0.01～100，默认 33.60 像素；每个非零输入轴先补足最短距离，再应用 0.5～10 的速度增益与反向，零位移轴不产生额外滚动。关闭平滑后不做步长保底，速度增益仍然生效。

平滑时长使用 1～5 的调节档位，每单位对应 100 毫秒，默认 1.80 对应 180 毫秒；偏好内部继续按秒保存，旧值低于 100 毫秒时调整到新下限。三个参数支持滑块、数值输入与增减按钮，以 0.01 精度显示两位小数。响应时长随剩余位移按连续曲线调整：小距离更快起步和收尾，大距离使用设置时长。小数余量在连续输入间保留，换向、窗口和修饰键变化保留原有清理策略。

鼠标设置先校验有效范围，再同步更新内存、偏好存储与运行服务；非有限数值恢复对应默认值，越界值限制到边界。重复写入相同有效值不再次保存或通知服务，避免不必要地打断滚动动画。数值输入草稿在提交或失去焦点时应用。

短距离的响应时长按设置时长乘以剩余像素相对八十像素的平方根计算，最长为设置时长，最短约十七毫秒；八十像素是动画调节的距离尺度，不是网页或事件类型判定阈值。输入仍仅通过原有系统滚轮字段处理，不查询网页地址、元素结构或浏览器标签，也不需要浏览器扩展或自动化权限。不同网页的视频切换规则由网页自身决定，应用不发送方向键、补发额外滚动或承诺任意网页都能一格切换。

鼠标页显示真实的启动与权限状态。首次开启不会后台弹出授权框；点击“开启辅助功能”复用现有授权入口。授权后返回应用会重试，也可在权限页刷新；启动失败可手动重试。无需单独申请输入监控权限。锁屏、休眠、会话离开时取消动画并释放接管，恢复后按保存配置启动；关闭增强立即交还原生滚动。

滚动计算与系统事件边界分离，事件接管和按需动画在专用串行运行循环中执行，动画空闲时不启动计时。设置保存在应用偏好中的 `mouseScrollConfiguration`，不迁移或复用剪贴板排除名单。应用不记录滚动轨迹或输入内容，不附带第三方进程，也不修改参考仓库。

```sh
# 合成事件、可控时间与模拟权限，不安装全局接管或向其他应用发送事件
./scripts/test.sh --filter MouseScroll
# 鼠标参数控件的离屏交互、输入校验、中英文与深浅外观；使用独立测试偏好
EASYMACOS_MOUSE_UI=1 ./scripts/test.sh --filter MouseScrollParameterViewTests
# 可选真实接管验证，仅向临时合成窗口发事件；需已有权限并先退出其他滚动增强工具
EASYMACOS_MOUSE_LIVE=1 ./scripts/test.sh --filter MouseScrollDeliveryTests
# 界面离屏渲染，包含六个标签及鼠标页的深浅外观
PASTEMAN_RENDER_TESTS=1 ./scripts/test.sh --filter RenderingTests
# 对已打开的设置窗口检查六标签与语言切换，结束后恢复原标签和语言
swift scripts/settings-smoke.swift
swift scripts/language-smoke.swift
# 核对安装后总开关与实际接管状态，结束时恢复原开关和标签
swift scripts/mouse-smoke.swift
```

真实鼠标与触控板需分别验收浏览器和访达中的滚动、换向、排除、关闭增强、锁屏恢复及钉图缩放。其他全局滚动工具应先关闭，避免叠加修改同一事件。

## Permissions

Three independent permissions are used:

1. **Clipboard access:** On macOS 15.4+, allow EasyMacOS in System Settings → Privacy & Security → Paste from Other Apps, choosing **Always Allow**. Use the app's permission button to initiate the first user-requested read. Background monitoring waits while access is Ask/Denied and does not repeatedly prompt. If the deep link is unavailable on a macOS release, navigate to that settings page manually. macOS 15.0–15.3 use the existing pasteboard access behavior.
2. **Accessibility:** Optional, for sending ⌘V to the previous app. EasyMacOS checks the system keyboard-event-posting permission and the foreground application immediately before sending events to that process. It cooperatively yields activation to the recipient and waits for stable focus and released modifier keys. If permission or the destination is unavailable, the selected item remains on the clipboard and the app asks you to paste manually. The app cannot verify whether the receiving application actually inserted the content or supports image paste. 鼠标增强同样使用辅助功能权限，只有用户开启增强后才接管滚轮事件；运行状态以实际创建并启用事件接管成功为准。

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

普通历史默认保留三十天、最多五百条，达到任一限制时清理；收藏优先显示并保留至手动删除。逻辑内容容量上限为五百一十二兆字节，包含文本、标准化图片和缩略图，不包含数据库额外空间、文件系统分配及日志开销。优先淘汰最旧的普通记录，收藏不会自动删除；收藏占满容量时跳过新内容并显示提示，释放空间后记录后续复制。启动、复制及保留设置变化时执行清理，后台清理按最近的过期时间调度，最长每小时回查一次；未删除内容时不刷新历史面板。清空历史默认保留收藏。

相同内容更新原记录的时间与来源，保留标识和收藏状态。来源取自半秒轮询检测时的前台应用，属于尽力判断；两次轮询之间的快速复制仍可能遗漏。处理已捕获图片期间继续检测后续复制。暂停和恢复会重新建立基线，不回填暂停期间的内容；暂停或清空时，尚在处理的图片失效。

正常记录每半秒检测一次；暂停或尚未完成引导时停止常规检测。锁屏、休眠及会话离开通知会暂停记录并取消待处理内容，恢复后重新建立基线。后台串行队列最多等待八条、合计三十二兆字节，超出时显示提示，便于用户稍后重新复制。剪贴板权限不可用时每五秒检查一次，恢复权限后建立新基线；恢复记录或完成引导会立即重新安排检测。

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

发布脚本构建 `arm64` 版本并启用强化运行时，先签署更新框架内的辅助程序、框架和沙盒访达扩展，再签署 EasyMacOS 宿主应用；随后验证签名、提交公证并附加公证票据，生成已签名的更新包与清单，再为磁盘映像签名、公证并进行系统安全评估。任一步骤失败都会停止。当前本机构建尚未执行开发者证书签名与公证；开发签名产物仅供本机验证。发布时应保持应用标识和签名身份稳定，以保留偏好设置与权限。

### 应用内检查更新

通用设置、菜单栏菜单和应用菜单共用同一更新服务。更新器采用精确锁定的 `Sparkle 2.10.1`，只在用户点击后启动；关闭自动检查、自动下载安装和系统信息上报。更新窗口使用应用当前界面语言。安装由更新组件负责，包含主应用及内嵌访达扩展，不迁移历史数据或偏好设置。

首次配置更新签名：

```sh
./scripts/setup-update-signing.sh
```

工具包下载后先校验固定摘要，缓存保存在 `.build/`。专用更新密钥保存在本机钥匙串的 `EasyMacOS-Update` 账户；重复运行复用原密钥，只把公钥写入 `scripts/Info.plist` 的 `SUPublicEDKey`。保留私钥，不导出到仓库或日志，也不要为重复构建更换更新密钥。

生成本地签名更新包：

```sh
./scripts/build.sh
./scripts/package-update.sh
```

脚本核对钥匙串公钥、主应用及扩展版本、嵌套代码签名后，生成 `dist/updates/EasyMacOS-版本号.zip` 和 `dist/updates/appcast.xml`，并校验压缩包签名。缺少密钥或不匹配时失败，不创建替代密钥。正式发布必须先通过 `scripts/release.sh` 完成签名和公证；该脚本在公证票据附加完成后生成更新包，压缩签名后不能继续修改包内容。

更新源为公开仓库的正式发行附件，清单固定地址为 `https://github.com/OldSixYao/EasyMacOS/releases/latest/download/appcast.xml`。发行标签使用 `v版本号`，例如 `v1.0.31`，同时上传对应版本的更新压缩包及 `appcast.xml`，不能标为预发布版本。清单包含实际构建号、显示版本、最低系统版本和纯文本更新说明；组件依据构建号拒绝相同版本和降级，更新包必须通过内置公钥校验后才能解包安装。脚本不自动提交源码或上传发行附件。

没有发行版本或更新清单时显示“暂时没有可用版本”；网络和服务器故障显示失败并允许重试。现有旧版没有更新入口，第一次需手动安装带此功能的应用，后续才可应用内升级。更新只请求版本清单及安装包，不传输剪贴板、截图或历史记录。

验证命令：

```sh
./scripts/test.sh --filter UpdateTests
EASYMACOS_UPDATE_UI=1 ./scripts/test.sh --filter UpdateTests
python3 scripts/update-smoke.py
```

界面验证选项会显示测试设置窗口，并把双语界面截图保存到临时目录，供检查按钮布局；入口共享、检查禁用与恢复由自动测试验证。隔离升级验证需已登录的图形桌面，会短暂显示并自动操作验证副本自身的更新窗口；不需要辅助功能权限。脚本使用随机应用标识、临时目录和仅监听回环地址的更新源，复用正式更新界面，验证下载、安装、重新启动、取消安装、版本拒绝及签名失败。验证宿主不启动剪贴板、截图、鼠标或访达服务，不替换正式应用；合成数据、日志和结果仅保留系统临时目录。

## Architecture

- `FinderMenuCore`：菜单动作、配置文件、结构化操作链接、路径格式化、目录选择与不覆盖创建逻辑。操作链接只接受固定动作和绝对本地路径，终端通过系统文件夹终端服务启动，使用独立剪贴板传参，不拼接执行脚本。
- `PasteMan`：唯一的宿主应用，提供剪贴板历史、截图、钉图、鼠标滚动增强、统一设置页，以及访达操作请求队列。
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

将 `EasyMacOS.app` 放入 `/Applications` 后打开设置中的“权限”标签页。点击“访达扩展”右侧的“开启…”或“管理…”调用系统访达扩展管理界面；在不同系统版本中，入口通常位于“通用 → 登录项与扩展 → 访达扩展”。启用显示名称为“EasyMacOS Finder Menu”的项目，再返回应用核对状态。应用不会自行更改系统扩展开关。

启用后，在普通本地目录中的文件、文件夹或空白处右键，常用操作直接显示在一级菜单，仅“新建文件”展开文件类型子菜单。新建会在所选文件夹内进行；选择普通文件时使用其所在目录。多选项目只有共同指向同一目录时才允许新建或打开终端，目录不明确时项目会禁用。应用包视作文件，避免在包内创建项目。路径和文件名支持多选逐行复制。新建按后缀创建“未命名.后缀”：`.docx` 使用空白文字模板，`.xlsx` 包含一个空工作表，`.pptx` 包含一张空白幻灯片，`.pdf` 为一页空白；原有文本类型和其他自定义后缀创建零字节文件。办公模板随共享核心资源包分发，不需要本机安装办公软件，模板读取失败直接提示且不创建空文件，遇到同名文件、目录或符号链接时依次尝试“未命名 2.后缀”等编号，不覆盖原项目。其他写入错误直接提示。

访达设置支持添加或删除文件类型，默认后缀为 `.txt`、`.json`、`.xml`、`.md`、`.csv`、`.html`、`.css`、`.js`、`.docx`、`.xlsx`、`.pptx`、`.pdf`。输入兼容一个前导点、首尾空白和大小写，并按规范化后缀去重；支持 `tar.gz` 等复合后缀，禁止空段、分隔符、冒号、内部空白、控制字符及过长名称。删除全部类型后隐藏新建菜单，恢复默认设置会恢复十二种默认类型与开关并重置类型图标，同时保留不复用的类型编号。宿主首次升级一次性追加缺少的四种办公类型，保留已有类型顺序、编号及开关，已有办公后缀直接复用；保存迁移标记后，删除的办公类型不会在重启后补回。扩展仅读取配置，不执行迁移。

创建后仅定位一次文件，最多等待两秒。已有辅助功能对象读取及键盘事件发送权限，且访达前台、唯一选区为新文件、修饰键已释放时，向该访达进程发送回车，再确认该文件的真实名称编辑框出现。用户切换应用、选区不符、未授权或超时均不向其他项目发送按键；取消重命名保留文件。普通失败显示三秒自动关闭的非激活提示，未授权时显示十秒的权限说明及“开启自动重命名…”按钮。设置中的“权限”标签页统一显示辅助功能授权状态并提供开启入口。只有用户点击授权按钮才请求系统权限，新建流程本身不主动请求权限，也不使用自动化脚本。授权后再次新建即可直接进入访达名称编辑状态。首次从历史临时签名迁移到固定证书，需要重新授权一次。

访达跨进程重建扩展菜单时可能丢失图标模板着色。菜单图标采用两种像素密度的普通透明位图，并保留模板标记，每次生成菜单时根据系统深浅外观解析系统文字语义颜色，避免扩展进程的黑色符号在深色访达菜单中直接显示。外观切换后下次右键生效。

文件类型的设置预览与菜单共用彩色默认图标。每行可通过“选择图片”导入系统支持的图片，保持比例缩小至最长边不超过一百二十八像素，转换为带透明通道的标准图片，独立存入 `~/Library/Application Support/EasyMacOS/file-type-icons/`。取消选择不改变配置；损坏或缺失资源回退默认图标。先保存新图片和配置，配置成功后才清理替换、删除及恢复默认设置不再引用的图片。恢复当前类型默认图标仅影响该类型；生成文件的图标继续由系统管理。文件类型菜单图标使用两种像素密度的非模板位图，保留原色及透明度。

配置写入 `~/Library/Application Support/EasyMacOS/finder-menu.json`，通过原子替换保存，下一次右键读取。关闭配置窗口或退出应用后，系统仍管理右键扩展；需要隐藏菜单时关闭“启用右键菜单”，需要完全停用扩展时使用系统设置。新建与打开终端会按需唤醒同一个 EasyMacOS 应用。

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


## 设置标签栏交互检查

打开已运行应用的设置窗口后，可使用调用进程已有的辅助功能权限验证标签栏：

```sh
swift scripts/settings-smoke.swift
```

脚本逐项点击五个标签，并验证左右方向键切换、首尾循环、唯一选中项与键盘焦点一致；结束后恢复原标签。仅读取界面元数据，不读写剪贴板、不更改设置、不请求权限。执行期间会暂时激活设置窗口。


## 界面语言

在“通用 → 界面语言”中选择“简体中文”或“English”，立即更新应用界面并保存到本机；未手动选择时按系统首选语言初始化。访达扩展通过共享配置读取选择，下次打开右键菜单时生效。切换语言不改变历史记录、快捷键或权限。

```sh
# 使用已有辅助功能权限，真实切换两种语言并恢复原语言及标签
swift scripts/language-smoke.swift
# 仅在测试进程中生成英文设置预览
PASTEMAN_RENDER_TESTS=1 PASTEMAN_RENDER_LANGUAGE=en PASTEMAN_RENDER_DIR=/tmp/easymacos-language-en ./scripts/test.sh --filter RenderingTests
```

语言交互检查会短暂激活设置窗口，并临时改变界面语言；不读写系统剪贴板、不请求权限。自动化语言保存测试使用独立偏好域和临时文件，不覆盖应用真实偏好。

## 可重复性能测量

合成测量使用发布优化配置、临时数据库和合成图片，不读取系统剪贴板，不捕获屏幕，不请求权限。结果仅保留在指定本地目录，不能提交或上传。每个耗时项目先预热一次，再测量七次；内存和捕获数量为独立场景测量。对比应在同一机器、相同系统和相同负载下顺序运行，避免与构建、其他测试或高负载任务重叠。

```sh
./scripts/benchmark.sh /tmp/easymacos-before-1
# 在另一份源码或完成改动后执行同一组负载
./scripts/benchmark.sh /tmp/easymacos-after-1
EASYMACOS_BENCHMARK_VISIBLE=1 ./scripts/benchmark.sh /tmp/easymacos-visible
./scripts/compare-benchmarks.py --before /tmp/easymacos-before-1 --after /tmp/easymacos-after-1 --output /tmp/easymacos-comparison.json
./scripts/profile-performance.sh 进程编号 /tmp/easymacos-process-sample 10
# 单独测量图片准备、截图导出和钉图缩放同时发生时的采样峰值
EASYMACOS_MIXED_BENCHMARK_OUTPUT=/tmp/easymacos-mixed ./scripts/test.sh -c release --filter OptimizationBenchmarks/measureMixedImageWorkload
# 大图变体：三项任务使用六千乘四千像素的同一合成原图
EASYMACOS_MIXED_LARGE=1 EASYMACOS_MIXED_BENCHMARK_OUTPUT=/tmp/easymacos-mixed-large ./scripts/test.sh -c release --filter OptimizationBenchmarks/measureMixedImageWorkload
# 输入路径微测量：不发送滚轮事件，图片仅写入并读取独立的临时剪贴板
EASYMACOS_INPUT_BENCHMARK_OUTPUT=/tmp/easymacos-input ./scripts/test.sh -c release --filter OptimizationBenchmarks/measureInputCosts
# 单独测量一百二十赫兹模拟时钟下的权限结果复用，不投递鼠标事件
EASYMACOS_MOUSE_PERMISSION_BENCHMARK_OUTPUT=/tmp/easymacos-mouse-permission ./scripts/test.sh -c release --filter OptimizationBenchmarks/measureMousePermissionCache
```

比较重要改动时，优化前后分别至少运行两次，把两次目录同时传入 `--before` 或 `--after`。离屏布局不等于可见首帧，局部绘制耗时不等于显示器帧率；测试进程物理占用与发布应用绝对占用不能混用。钉图合成场景固定窗口内容尺寸并等待显示位图准备完成，不将未解码占位状态计为完成。

设置 `EASYMACOS_BENCHMARK_VISIBLE=1` 会短暂显示多张合成钉图并自动关闭，用于计入真实窗口的显示开销，不捕获屏幕或读取用户图片。应只在方便显示测试窗口时使用，并把可见、离屏结果分别对比。创建耗时包含原图后备与显示位图准备；另有六张小钉图期间增减窗口和连续四十次缩放负载。阶段峰值是离散采样最大值，不是连续采样的绝对峰值。

混合图片负载每次使用独立测试进程，按约一毫秒间隔采样物理占用；开始前已经生成原图、压缩数据和钉图后备。应重复多次独立运行，采样峰值不能当作连续绝对峰值。各图片模块保留独立的串行工作器，钉图的显示预算不包含原图输入、处理临时缓冲、窗口合成器和系统缓存，不能当作进程物理内存上限。输入路径微测量不能代表外部应用延迟提供剪贴板内容时的等待，也不能推断真实耗电。

应用通过系统性能标记记录 `HistoryFirstPage`、`HistoryQuery`、`HistorySave`、`ScreenshotExport`、`SystemScreenCapture`、`ClipboardRead` 和 `ClipboardProcessing` 阶段。可在完整开发工具的性能分析器中按应用子系统筛选；仅安装命令行工具的机器可先使用进程采样脚本观察主线程栈。标记不包含文本、图片、路径和来源名称。真实多屏截图延迟、可见交互帧率和硬件耗电需要在对应设备上单独测量，不能从合成数据推断。


## 办公模板与类型图标维护

四种模板位于 `Sources/FinderMenuCore/Resources/OfficeTemplates/`，由共享核心声明为资源；构建脚本把完整资源包复制到宿主及扩展资源目录。运行时只读取内置模板，不访问外部模板或办公应用。

```sh
# 压缩包、必要部件、全部内部关联及空白内容检查
python3 scripts/validate-office-templates.py
# 系统便携文档解析、创建保护、迁移、图标导入及回滚、菜单传递检查
./scripts/test.sh --filter Finder
# 真实访达菜单连续创建四种办公文档并检查内容、重名和原地重命名
swift scripts/finder-smoke.swift "$PWD/dist/EasyMacOS.app" --office-only --expect-rename
```

仅在维护模板资源时，需要在独立环境安装 `python-docx`、`openpyxl` 和 `python-pptx`，再运行 `python3 scripts/make-office-templates.py`。这些工具不是应用或构建的依赖。三类压缩包模板采用完整的默认样式与关联，便携文档采用标准页树与交叉引用表。修改模板后同时运行结构检查，并用本机可用办公应用打开验证无损坏或修复提示。验证日志和界面截图仅保留本地。
