# 交接说明

新会话先读本文；已支持的功能清单见 [FEATURES.md](FEATURES.md)（新增功能后同步更新）。再按需查 [DEVELOPMENT_LOG.md](DEVELOPMENT_LOG.md)（每阶段的决策、根因与验证）和 [ROADMAP.md](ROADMAP.md)。需求见 [产品需求文档.md](产品需求文档.md)。

## 当前状态（2026-11-12，分支 `leading`；3G-1 至 3I-2 已提交，均未推送）

已完成：阅读与搜索（含正则/全词）、标准批注（高亮/下划线/波浪线/删除线/笔记/文本框/手绘/形状，可调颜色、粗细、字体；选中文字后的浮动标注工具条；不透明度与常用样式；文本框背景与边框）、批注编辑（选择、缩放、移动、复制粘贴、批量删除）、页面管理（旋转、删除、插入、移动、提取）、用户书签（⌘B，存于应用、按文件）、批注列表按类型/颜色/作者筛选、加密文档密码可记在钥匙串（设置中可忘记）、设置/更改/移除打开密码与权限限制（受限文件只读并有提示条）、所选文字的系统翻译浮层与朗读、导出时减小文件大小、裁切页面、拆分文档、幻灯片放映、插入图片、网址链接、签名（手写/键入/图片，可存储复用）、水印、页眉页脚与页码、表单填写（存储时修复 PDFKit 写坏的单选组）、导出文字（TXT/RTF/Word）、图片转 PDF（合并窗口）、识别文字（Vision，加不可见文字层）、涂黑（标记后应用，页面重画为图像）、批量处理（压缩/识别文字/页码/水印/导出文字）、报告问题（帮助菜单；系统与文稿信息、崩溃报告、本次日志；邮件或问题页面，目的地在 Info.plist 中设置；意外退出后提示）、合并文档（合并窗口：排序、页码范围、逐页预览）、导出（PDF 副本/扁平化、图片）、多标签页与多窗口、开始页与最近文件、自动存储、中英文界面与设置（⌘,）、外观（跟随系统/浅色/深色，设置与“显示”菜单）、打印、常用快捷键。Debug/Release、签名/未签名构建均 0 警告；42 项核心测试通过。

## 下一步候选（按优先级）

0. 发布前在 `Configuration/Info.plist` 填上 `PaperplaneSupportEmail` 和/或 `PaperplaneIssuesURL`（留空则报告窗口只能拷贝、存储），并按需修改 `MARKETING_VERSION`。
1. PDFgear 差距第 2 组已全部完成（3H-1 至 3H-6）。可补：批量处理加密文件、多操作组合；文字导出的页码范围；图片转 PDF 的页边距。
2. 第 3 组（困难）：修改原有文字（PDFKit 不能改内容流）、PDF 转 Office、创建表单、证书签名、本地 AI 摘要；页内链接（需修复 PDFKit 写坏页面引用的问题，见下方坑）。
3. U-04 补全：双指旋转手势（P0）；幻灯片的触控板手势翻页。
4. 需要用户确认的项：见 DEVELOPMENT_LOG 各阶段未勾选项（3F-4 起），主要是拖动、手感、沙盒中的文件夹与面板、在其他应用中的显示。

## 项目约定

- 每个阶段在 `docs/DEVELOPMENT_LOG.md` 末尾（“事故与风险记录”之前）加一节 checklist，写明根因、决策与验证；未在真机验证的项留为 `[ ]`。
- 提交信息用英文，末尾附 `Co-Authored-By` 行；只在用户要求时提交。
- 界面文字一律经 `L("English text")`，在 `Sources/*/Resources/{en,zh-Hans}.lproj/Localizable.strings` 两份表中同时增删；用脚本核对代码中的键与两表完全一致（无缺失、无多余）。
- Xcode 工程是显式文件清单：新增 `.swift` 文件必须登记到 `Paperplane.xcodeproj/project.pbxproj`（PBXBuildFile、PBXFileReference、Sources 组、对应 Sources 构建阶段），否则 Xcode 构建报 “Cannot find … in scope”。在 Xcode 外改过工程文件后，需在 Xcode 中关闭并重开工程。
- 交付前：`swift test`；`xcodebuild -project Paperplane.xcodeproj -scheme Paperplane clean build CODE_SIGNING_ALLOWED=NO` 保持 0 警告（需要检查权限时用 `CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=""` 做签名构建）。

## 架构要点

- `AppModel`：全应用共享（窗口登记、打开路由与标签页、最近文件、批注剪贴板）。每个窗口一个 `ReaderLibrary`（文稿与全部编辑状态）。菜单经 `ReaderCommands` 作用于关键窗口的文稿，仅在确知无文稿时禁用。
- 所有文稿修改最终调用 `annotationsDidChange()`：计数（随撤销/重做增减，决定“已编辑”）、刷新、安排自动存储。页面顺序变化统一走 `changePageOrder(to:)`；批注几何变化统一走 `commitGeometry`。
- 存储一律经 `SafePDFFileStore.save`（协调、外部修改检测、写副本并重开校验、原子替换或沙盒下原地覆盖）。存储/导出/打印前用 `withNativeNotesRestored` 恢复标准形态，并排除待确认的批注。

## PDFKit 的坑（已绕过，改动相关代码前务必了解）

- macOS 27 上 PDFKit 以低分辨率栅格化批注：手绘、形状、文本框与笔记图标在屏幕上由页面覆盖层矢量绘制，PDFKit 自身渲染在屏幕上隐藏（`shouldDisplay = false`），存储时临时恢复。标注上的笔记屏幕上暂存于内存，因为带 `/Contents` 的标注会被 PDFKit 画出随页面缩放的徽标。
- 覆盖层提供者必须在设置 `document` 之前设置，否则 PDFKit 不请求覆盖层。
- `PDFAnnotation.copy()` 得到的批注能显示但不会写入文件；需从原批注字典新建（去掉 `/P`、`/Popup`）再应用几何。
- `PDFPage.copy()` 会给每个笔记附加原页面没有的 Popup（新 SDK 链接的程序中才会；`swift` 脚本里不会），写出后多一个批注。复制页面一律用 `DocumentMerger.copy(of:)`；不要在原页面上读取 `popup`，否则笔记文字会丢失。
- 文本框的字体、颜色只写入外观流，重开读回为黑色 Helvetica 12、边框 1；用自定义键 `/PaperplaneTextStyle` 保存并在打开时恢复。用 KVC 写 `/DA` 无效。
- PDFKit 把批注透明度只写进外观流，重开读回不透明；用 `/PaperplaneOpacity` 保存并在页面准备时恢复。`fontColor` 设置时即丢弃 alpha，所以文本框不提供不透明度。
- PDFKit 总把文本框边框画成黑色（`/MK`、`/DA` 写法会让它崩溃），所以边框只有粗细；背景（`color`）与边框粗细能原样保存。
- PDFKit 写出的 `/Squiggly` 外观流为空且没有 QuadPoints；波浪线存为带 `/PaperplaneSquiggly` 的下划线，由覆盖层画波浪；波浪的位置与缺口由 `SquiggleInk` 按页面文字墨迹计算（避让下伸字母，中文放在字形下方），按批注缓存。文字标注种类统一用 `MarkupEngine.tool(of:)` 判断，新增文字标注工具加进 `AnnotationTool.markupTools` 即可。
- `findString` 不支持正则；搜索改用 `NSRegularExpression` 遍历页面文本。
- `PDFPage.draw(with:to:)` 自带页面旋转，不要再叠加 `transform(for:)`。
- SwiftUI 在新窗口第一次布局时（`NSHostingView.updateAnimatedWindowSize`）把它调成内容的初始尺寸；新窗口并入标签组要延后一轮主线程循环（见 `AppModel.windowDidAppear`），否则整个标签组会被缩小。
- `PDFView.visibleRect` 可能比视图本身还大；求 PDF 视图的可视区域用 `bounds`。
- 颜色比较：调色板是校准 RGB，PDFKit 读回为设备 RGB、分量相同（可能差 1/255），所以按存储的分量比较，不要都转换到设备 RGB（见 `MarkupColor(nearest:among:)`）。`NSColor.black` 等是灰度色，直接读 `redComponent` 会抛异常。PDFKit 新建批注时自动填 `userName`（系统用户全名）。
- 外观：`AppearanceSetting.shared` 设置 `NSApp.appearance`；需要固定浅色的浮窗自行设 `.aqua`。SwiftUI 菜单的勾选在菜单打开时才刷新（探针中要先调菜单代理）。
- 钥匙串：用登录钥匙串的通用密码项（`PasswordKeychain`），沙盒内可用；数据保护钥匙串需要团队 ID，临时签名用不了。项的访问控制绑定创建它的构建：工程未设团队，Xcode 构建为临时签名，重新构建后读取旧项会弹系统授权框（已验证）；`SecItemUpdate` 不会改访问控制，所以存储一律先删后建。
- 加密：PDFKit 只写 128 位 RC4；没有所有者密码就不加密（只设打开密码时两者取同值）；以受限身份解锁时存储会静默丢掉新批注，所以受限文件在界面上只读（`canAnnotate`/`canChangePages`/`canPrint`/`canCopy`，见 `DocumentSecurity.swift`；修改已有批注的方法也都检查 `canAnnotate`），存储也有兜底。设置限制后窗口以读者身份重新打开，立即受限。PDFKit 的默认右键菜单在已有标注上带自己的标注项，返回前一律用 `removeNativeAnnotationItems` 去掉。移除密码用空密码写出（`PDFPasswordSettings.removalOptions`）。
- 翻译用 `translationPresentation`（macOS 14.4+，弱链接），浮层由系统进程绘制，截图截不到内容。朗读的语句状态按当前 `AVSpeechUtterance` 跟踪。
- 压缩：PDFKit 的 `saveImagesAsJPEGOption`/`optimizeImagesForScreenOption` 不起作用，用系统“Reduce File Size” Quartz 滤镜（写入选项 `QuartzFilter`，沙盒中可用）。
- 图片、签名用 `ImageStamp`（自绘图章，存储时写入外观流）；重新打开后是普通图章，可移动缩放但不可复制（复制由字典重建，没有外观流）。
- 自绘批注（`PDFAnnotation` 子类覆写 `draw`）：`PDFPage.copy()` 用 `copy(with:)` 复制、不走初始化方法，必须覆写 `copy(with:)`；扁平化（`burnInAnnotationsOption`）会画成叉框，须先写出再读回后扁平化（`DocumentExporter` 已处理）；`beginTransparencyLayer` 写出后其他阅读器找不到表单对象，不要用；`PDFPage.thumbnail` 不管 `shouldDisplay` 都画批注，且在旋转页上方向错误（应用中，单元测试进程中不会），`page.draw(with:to:)` 则不画隐藏的批注。
- 表单：PDFKit 自己编辑域并登记撤销，改值发 `PDFFormDidChangeValue`（对象为文稿）；改过的复选/单选按钮被 PDFKit 写坏（导出名变 “Yes”，单选组重开后同名），存储、导出副本、提取/拆分/合并后由 `ButtonFieldRepair` 追加增量更新修复（加密文件除外）；复制出的按钮不知道自己是否选中，状态要从源页面读。受限文件中点表单域被拦截。
- PDFKit 实时 OCR：应用中 `PDFView` 显示过或搜索过的纯图片页面，PDFKit 会自动识别并把文字注入该页（`string`、`pageRef` 内容流），存储时可能写出也可能不写；`saveTextFromOCROption` 只对这些页面有效。判断“页面是否真有文字”要用写出再读回的副本（`TextRecognizer.hasText` 扫描内容流）。
- `replacePages`（`PageOperations.swift`）用新页面替换旧页面并移交批注对象（`leaving` 中的留在旧页），撤销时移回；识别文字与涂黑用它。替换后 `cacheDisplay` 截图仍显示旧页面内容，验证用像素渲染或写出的文件。
- Quartz“Reduce File Size”滤镜会让图片少的小文件变大（2 KB → 18 KB）；批量处理中不比原文件小就放弃输出。
- `PDFPage(image:options:)` 只要传入选项（即使为空）就按像素定页面尺寸、忽略图片分辨率；要原尺寸用不带选项的 `PDFPage(image:)`。
- 水印、页眉页脚是 `PageMark`（`PageMarks.swift`），设置以 JSON 存在 `/PaperplaneWatermark`、`/PaperplaneHeaderFooter` 中；打开时文字类重建为可更新的对象，屏幕上由覆盖层绘制；页面变化后 `refreshPageMarks` 重新编号与布置。几何在 Core 的 `PageMarkLayout`。
- `CGRect` 的 width/height 总是非负，判断“剩余是否足够”要先算差值再建矩形（裁切曾因此出错）。
- PDFKit 对从文件打开的文稿新建页内链接/目录项时，把目标页写成占位名称（`/#2323<页码>`），存储后失效；已有链接重新存储正常。
- PDFKit 写出含文本框的文件时，外观流里嵌入字体的数据流缺 `/Length`（与字体无关），Ghostscript 能自动修复。
- `PDFView` 未公开 `validateMenuItem`，需通过运行时调用其实现。
- 沙盒应用打印需要 `com.apple.security.print`；沙盒只授权所选文件而非其文件夹。

## 诊断日志

打开文件的每一步记在 `Logger.opening`（子系统 `app.paperplane.reader`，类别 `open`）；显示给用户的错误与“上次意外退出”记在 `Logger.problems`（类别 `problem`）。“报告问题”窗口会附上本次运行的这些日志。出问题后运行：

```
log show --last 10m --info --predicate 'subsystem == "app.paperplane.reader" AND category == "open"'
```

“⌘O 选了文件却没打开”尚未复现，见 DEVELOPMENT_LOG 阶段 3D-5。

## 本地探针（验证方法）

### 推荐做法：应用副本 + 环境变量钩子（本阶段 3D 起一直使用）

1. 把整个工程复制到临时目录：`rsync -a --exclude .build --exclude .git ./ "$TMPDIR/xx/src/"`，只在副本里改，正式源码不动。
2. 在副本的 `AppModel.register(_:)` 开头插入：环境变量 `PP_DIR` 存在且是第一个窗口时，`DispatchQueue.main.asyncAfter` 后调用一个 `@MainActor enum XxProbe { static func run(_ library: ReaderLibrary) }`，在里面打开测试文件、直接调用 `ReaderLibrary` 的方法、用 `NSLog("PPDEBUG PASS/FAIL …")` 输出检查结果，最后 `exit(0)`。
3. 构建：`xcodebuild -project Paperplane.xcodeproj -scheme Paperplane build CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" CODE_SIGN_ENTITLEMENTS=<空 plist> ENABLE_APP_SANDBOX=NO PRODUCT_BUNDLE_IDENTIFIER=app.paperplane.probe -derivedDataPath <临时目录>`。必须同时关 `ENABLE_APP_SANDBOX`（只换 entitlements 不够），否则读不了临时目录的测试文件；独立 bundle ID 避免污染用户正式应用的 UserDefaults（常用样式、书签等）。
3a. 只验证沙盒内的行为（如钥匙串）时，可不传 `CODE_SIGN_ENTITLEMENTS`/`ENABLE_APP_SANDBOX`，用正式 entitlements 构建另一个 bundle ID，探针不读临时目录里的文件。
4. 直接运行可执行文件（不要用 `open`，用户可能正从 Xcode 运行着正式应用）：`PP_DIR=… …/Paperplane.app/Contents/MacOS/Paperplane -NSQuitAlwaysKeepsWindows NO -ApplePersistenceIgnoreState YES -AppleLanguages "(zh-Hans)" > log 2>&1 &`，用带超时的循环等待并 `grep PPDEBUG`（管道里的 grep 会缓冲，进程挂起时看不到输出，所以先写文件）。
5. 注意：撤销要 `groupsByEvent = false` 并给每步手动开关分组，否则抛 “must begin a group”（在探针 Task 里这个异常被静默吞掉，表现为探针停在那一步、主线程空闲）；嵌套函数要标 `@MainActor`；`hasUnsavedChanges` 等只读属性不能在探针里改；窗口打开后当前页可能不是第 1 页（粘贴等会落到当前页）；整页逐像素用 `colorAt` 太慢，用 `bitmapData` 并只扫描相关区域。
6. 截图只能截到 SwiftUI 界面与页面覆盖层，截不到 PDFKit 自己绘制的批注（`cacheDisplay` 与 `CALayer.render` 都截不到，系统 `screencapture -l` 无权限）；批注外观用缩略图、`page.draw` 或 Ghostscript 验证。截图（浮层为半透明材质，`cacheDisplay` 截不到其中的主色文字，先给内容视图设不透明的 `layer.backgroundColor` 再截）：`contentView.bitmapImageRepForCachingDisplay` + `cacheDisplay` 写 PNG 后用 Read 查看；子窗口（浮动工具条）从 `window.childWindows` 取；视觉材质在截图中呈灰底属正常。

### 事件注入探针：验证真实交互（阶段 3F-4 起）

脚本与探针代码在会话共享笔记目录 `ui-event-probe/`（仓库外）。要点：

- 在探针应用内用 `NSEvent.mouseEvent` / `keyEvent` + `NSApp.postEvent` 向它自己的窗口发送事件；一次排入按下、若干拖动、松开即可，PDFView 的拖选跟踪会依次取走。窗口坐标由页面坐标经 `view.convert(_:from: page)` 与 `view.convert(_:to: nil)` 得到。
- 用 `open -n <探针.app> --env PP_DIR=… --stdout … --args …` 启动（独立 bundle ID 时可用）。直接从终端运行可执行文件，应用约 1 秒后就被其他应用夺走激活状态，浮动工具条（`hidesOnDeactivate`）与临时气泡随之消失。
- SwiftUI 只在有辅助功能客户端时生成辅助功能树，进程内查不到控件；在探针副本里给控件加 `.probeFrame("id")`（不接受点击的背景 NSView）取窗口坐标。
- 探针任务运行在主队列上，NSAlert 模态循环里不会再执行 GCD 主队列块；要在弹窗期间操作，用同时加入 `.common` 与 `.modalPanel` 模式的 `Timer`。
- 安全输入框只接受第一个合成按键；密码直接设 `stringValue`，再用鼠标点按钮。
- 撤销测试：应用失去激活时不处理事件，按事件分组的撤销组不会关闭，几步操作会被合成一步；探针里用 `groupsByEvent = false` 并手动开关分组。探针应用失去激活时拖动类测试（移动批注）无法进行。
- 需要应答 NSAlert 时，更简单的做法是在探针副本里把 `alert.runModal()` 替换成一个按脚本应答的函数（阶段 3F-5 的 `ProbeModal`）。
- 探针以 `exit()` 结束，不经过正常退出，所以下次启动会弹出“上次意外退出”表单。`run-open.sh` 传入 `-doesNotAskAboutUnexpectedQuits YES` 来关闭它；验证这一提示时设 `PP_ASK_QUIT=NO`。
- 编辑气泡（`_NSPopoverWindow`）也是窗口的子面板，找浮动工具条时要排除它。
- `pkill -f`/`pgrep -f` 的模式会匹配到执行它的 shell，写成 `"[u]i/dd/Build/Products"`。
- 其他阅读器的效果：`gs -sDEVICE=png16m -r144 -o out.png file.pdf`（/usr/local/bin/gs），或用全新 `PDFDocument` 的 `page.draw` 渲染（即“预览”所见）后取像素。

### 摸清 PDFKit 行为：临时单元测试

PDFKit 在命令行 `swift` 脚本与应用/测试包中的行为不同（例如 `PDFPage.copy()` 的 Popup），所以写临时的 `Tests/PaperplaneCoreTests/ZZProbeTests.swift`，`swift test --filter ZZProbeTests 2>&1 | grep PROBE`，用完删除。新功能动手前先这样验证存储往返（写文件、用 `PDFDocument(url:)` 重开）和外观流（用 `page.draw` 渲染，或解压文件里的流），本阶段的透明度、文本框边框、波浪线都是这样发现限制的。

### 字符串核对脚本

```python
import re,glob
for target in ["Paperplane","PaperplaneCore"]:
    code=set()
    for f in glob.glob(f"Sources/{target}/*.swift"):
        code |= set(re.findall(r'\bL\("((?:[^"\\]|\\.)*)"', open(f).read()))
    for lang in ["en","zh-Hans"]:
        t=set(re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=', open(f"Sources/{target}/Resources/{lang}.lproj/Localizable.strings").read(), re.M))
        print(target, lang, "missing:", sorted(code-t), "extra:", sorted(t-code))
```

新增工程文件的 ID 已用到 `…067`（Core `PageTools.swift` 050、`PageToolSheets.swift` 051、`Slideshow.swift` 052、`InsertTools.swift` 053、`Signatures.swift` 054、Core `PageMarkLayout.swift` 055、`PageMarks.swift` 056、`PageMarkSheets.swift` 057、Core `ButtonFieldRepair.swift` 058、`FormFields.swift` 059、Core `DocumentConverter.swift` 060、Core `TextRecognition.swift` 061、`TextRecognitionSheet.swift` 062、Core `Redaction.swift` 063、`Redactions.swift` 064、`BatchWindow.swift` 065、Core `BugReport.swift` 066、`BugReportWindow.swift` 067），下一个从 `100000000000000000000068` / `200000000000000000000068` 开始（共 24 位，注意别多写一个 0）。Core 文件登记在 Core Sources 构建阶段。

### 旧做法：手工编译源码

验证新功能时，把 `Sources/Paperplane/*.swift` 与 `Sources/PaperplaneCore/*.swift` 拷到临时目录（删除 `import PaperplaneCore` 行），加一个 `@main` 的 `main.swift`，编译后放进一个最小 `.app` 包（含两份 `Localizable.strings` 合并后的 `lproj`），用 `-AppleLanguages "(zh-Hans)"` 运行，直接调用 `ReaderLibrary` 或向 `PDFView` 发送 `NSEvent`。注意：

- 覆盖已运行过的可执行文件前先删除再拷贝，否则代码签名缓存失效，进程启动即被 SIGKILL（退出码 137）。
- 关闭撤销的自动分组（`groupsByEvent = false`）并为每步手动开关分组，否则连续操作会合并成一个撤销步骤；文本视图输入与粘贴也要放在分组内。
- 离屏窗口无法模拟 PDFView 自己的拖动跟踪，拖选与拖放需真机确认；瞬态气泡在非活动应用中不显示，可把控制器放进普通窗口截图。
- 截图用 `bitmapImageRepForCachingDisplay` + `cacheDisplay`；`NSHostingView` 坐标翻转（顶部 y = 0）。
- SwiftUI 运行时警告只进系统日志：`/usr/bin/log stream --predicate 'process == "…" AND eventMessage CONTAINS "Publishing changes"'`（zsh 中 `log` 是内建命令；计数时别把日志头一行算进去）。
- 要测试菜单、标签页等需真实 SwiftUI 场景的行为，用应用自身的 `@main` 入口，用 `open -W -n --stdout … P.app` 启动。
