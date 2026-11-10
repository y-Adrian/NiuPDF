# 交接说明

新会话先读本文，再按需查 [DEVELOPMENT_LOG.md](DEVELOPMENT_LOG.md)（每阶段的决策、根因与验证）和 [ROADMAP.md](ROADMAP.md)。需求见 [产品需求文档.md](产品需求文档.md)。

## 当前状态（2026-11-10，分支 `leading`，最新提交 `aaba39c`，N-04 已完成待提交，未推送）

已完成：阅读与搜索（含正则/全词）、标准批注（高亮/下划线/波浪线/删除线/笔记/文本框/手绘/形状，可调颜色、粗细、字体；选中文字后的浮动标注工具条；不透明度与常用样式；文本框背景与边框）、批注编辑（选择、缩放、移动、复制粘贴、批量删除）、页面管理（旋转、删除、插入、移动、提取）、用户书签（⌘B，存于应用、按文件）、批注列表按类型/颜色/作者筛选、合并文档（合并窗口：排序、页码范围、逐页预览）、导出（PDF 副本/扁平化、图片）、多标签页与多窗口、开始页与最近文件、自动存储、中英文界面与设置（⌘,）、打印、常用快捷键。Debug/Release、签名/未签名构建均 0 警告；9 项核心测试通过。

## 下一步候选（按优先级）

1. S-02 钥匙串记住密码：打开加密 PDF 时可选“记住密码”，存入钥匙串（按文件），下次自动解锁；设置里可清除。注意沙盒与 `ReaderLibrary.askForPassword`（打开与合并共用）。
2. P1：OCR、表单填写与签名、压缩、密码保护、夜间模式、分屏、链接、标注摘要导出。
3. 需要用户在实际应用中确认的未勾选项（DEVELOPMENT_LOG 阶段 3D-3 起：合并窗口、浮动工具条、不透明度、文本框样式、波浪线、书签重命名、批注筛选浮层）。这些只能由用户操作确认，不必等它们再开工。

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
- `PDFView` 未公开 `validateMenuItem`，需通过运行时调用其实现。
- 沙盒应用打印需要 `com.apple.security.print`；沙盒只授权所选文件而非其文件夹。

## 诊断日志

打开文件的每一步记在 `Logger.opening`（子系统 `app.paperplane.reader`，类别 `open`）。出问题后运行：

```
log show --last 10m --info --predicate 'subsystem == "app.paperplane.reader" AND category == "open"'
```

“⌘O 选了文件却没打开”尚未复现，见 DEVELOPMENT_LOG 阶段 3D-5。

## 本地探针（验证方法）

### 推荐做法：应用副本 + 环境变量钩子（本阶段 3D 起一直使用）

1. 把整个工程复制到临时目录：`rsync -a --exclude .build --exclude .git ./ "$TMPDIR/xx/src/"`，只在副本里改，正式源码不动。
2. 在副本的 `AppModel.register(_:)` 开头插入：环境变量 `PP_DIR` 存在且是第一个窗口时，`DispatchQueue.main.asyncAfter` 后调用一个 `@MainActor enum XxProbe { static func run(_ library: ReaderLibrary) }`，在里面打开测试文件、直接调用 `ReaderLibrary` 的方法、用 `NSLog("PPDEBUG PASS/FAIL …")` 输出检查结果，最后 `exit(0)`。
3. 构建：`xcodebuild -project Paperplane.xcodeproj -scheme Paperplane build CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" CODE_SIGN_ENTITLEMENTS=<空 plist> ENABLE_APP_SANDBOX=NO PRODUCT_BUNDLE_IDENTIFIER=app.paperplane.probe -derivedDataPath <临时目录>`。必须同时关 `ENABLE_APP_SANDBOX`（只换 entitlements 不够），否则读不了临时目录的测试文件；独立 bundle ID 避免污染用户正式应用的 UserDefaults（常用样式、书签等）。
4. 直接运行可执行文件（不要用 `open`，用户可能正从 Xcode 运行着正式应用）：`PP_DIR=… …/Paperplane.app/Contents/MacOS/Paperplane -NSQuitAlwaysKeepsWindows NO -ApplePersistenceIgnoreState YES -AppleLanguages "(zh-Hans)" > log 2>&1 &`，用带超时的循环等待并 `grep PPDEBUG`（管道里的 grep 会缓冲，进程挂起时看不到输出，所以先写文件）。
5. 注意：撤销要 `groupsByEvent = false` 并给每步手动开关分组，否则抛 “must begin a group”；嵌套函数要标 `@MainActor`；`hasUnsavedChanges` 等只读属性不能在探针里改；窗口打开后当前页可能不是第 1 页（粘贴等会落到当前页）；整页逐像素用 `colorAt` 太慢，用 `bitmapData` 并只扫描相关区域。
6. 截图（浮层为半透明材质，`cacheDisplay` 截不到其中的主色文字，先给内容视图设不透明的 `layer.backgroundColor` 再截）：`contentView.bitmapImageRepForCachingDisplay` + `cacheDisplay` 写 PNG 后用 Read 查看；子窗口（浮动工具条）从 `window.childWindows` 取；视觉材质在截图中呈灰底属正常。

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

新增工程文件的 ID 已用到 `…045`（`AnnotationFilter.swift`），下一个从 `100000000000000000000046` / `200000000000000000000046` 开始。

### 旧做法：手工编译源码

验证新功能时，把 `Sources/Paperplane/*.swift` 与 `Sources/PaperplaneCore/*.swift` 拷到临时目录（删除 `import PaperplaneCore` 行），加一个 `@main` 的 `main.swift`，编译后放进一个最小 `.app` 包（含两份 `Localizable.strings` 合并后的 `lproj`），用 `-AppleLanguages "(zh-Hans)"` 运行，直接调用 `ReaderLibrary` 或向 `PDFView` 发送 `NSEvent`。注意：

- 覆盖已运行过的可执行文件前先删除再拷贝，否则代码签名缓存失效，进程启动即被 SIGKILL（退出码 137）。
- 关闭撤销的自动分组（`groupsByEvent = false`）并为每步手动开关分组，否则连续操作会合并成一个撤销步骤；文本视图输入与粘贴也要放在分组内。
- 离屏窗口无法模拟 PDFView 自己的拖动跟踪，拖选与拖放需真机确认；瞬态气泡在非活动应用中不显示，可把控制器放进普通窗口截图。
- 截图用 `bitmapImageRepForCachingDisplay` + `cacheDisplay`；`NSHostingView` 坐标翻转（顶部 y = 0）。
- SwiftUI 运行时警告只进系统日志：`/usr/bin/log stream --predicate 'process == "…" AND eventMessage CONTAINS "Publishing changes"'`（zsh 中 `log` 是内建命令；计数时别把日志头一行算进去）。
- 要测试菜单、标签页等需真实 SwiftUI 场景的行为，用应用自身的 `@main` 入口，用 `open -W -n --stdout … P.app` 启动。
