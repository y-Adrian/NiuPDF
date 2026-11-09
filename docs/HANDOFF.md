# 交接说明

新会话先读本文，再按需查 [DEVELOPMENT_LOG.md](DEVELOPMENT_LOG.md)（每阶段的决策、根因与验证）和 [ROADMAP.md](ROADMAP.md)。需求见 [产品需求文档.md](产品需求文档.md)。

## 当前状态（2026-11-10，分支 `leading`）

已完成：阅读与搜索（含正则/全词）、标准批注（高亮/下划线/删除线/笔记/文本框/手绘/形状，可调颜色、粗细、字体）、批注编辑（选择、缩放、移动、复制粘贴、批量删除）、页面管理（旋转、删除、插入、移动、提取）、导出（PDF 副本/扁平化、图片）、多标签页与多窗口、开始页与最近文件、自动存储、中英文界面与设置（⌘,）、打印、常用快捷键。Debug/Release、签名/未签名构建均 0 警告；7 项核心测试通过。

## 下一步候选（按优先级）

1. P-03 合并文档：专门的合并窗口（预览与排序）；目前可用“从文件插入页面”或把 PDF 拖到缩略图上代替。
2. A-01 选中文字后的浮动工具条；A-02 透明度与样式预设；A-04 文本框边框/背景色。
3. N-02 用户书签；N-04 批注列表按类型/颜色/作者筛选；S-02 钥匙串记住密码。
4. P1：OCR、表单填写与签名、压缩、密码保护、夜间模式、分屏、链接、标注摘要导出。

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
- `PDFAnnotation.copy()` 得到的批注能显示但不会写入文件；需从原批注字典新建（去掉 `/P`、`/Popup`）再应用几何。`PDFPage.copy()` 则正常（插入/提取页面可用）。
- 文本框的字体、颜色只写入外观流，重开读回为黑色 Helvetica 12、边框 1；用自定义键 `/PaperplaneTextStyle` 保存并在打开时恢复。用 KVC 写 `/DA` 无效。
- `findString` 不支持正则；搜索改用 `NSRegularExpression` 遍历页面文本。
- `PDFPage.draw(with:to:)` 自带页面旋转，不要再叠加 `transform(for:)`。
- `PDFView` 未公开 `validateMenuItem`，需通过运行时调用其实现。
- 沙盒应用打印需要 `com.apple.security.print`；沙盒只授权所选文件而非其文件夹。

## 本地探针（验证方法）

验证新功能时，把 `Sources/Paperplane/*.swift` 与 `Sources/PaperplaneCore/*.swift` 拷到临时目录（删除 `import PaperplaneCore` 行），加一个 `@main` 的 `main.swift`，编译后放进一个最小 `.app` 包（含两份 `Localizable.strings` 合并后的 `lproj`），用 `-AppleLanguages "(zh-Hans)"` 运行，直接调用 `ReaderLibrary` 或向 `PDFView` 发送 `NSEvent`。注意：

- 覆盖已运行过的可执行文件前先删除再拷贝，否则代码签名缓存失效，进程启动即被 SIGKILL（退出码 137）。
- 关闭撤销的自动分组（`groupsByEvent = false`）并为每步手动开关分组，否则连续操作会合并成一个撤销步骤；文本视图输入与粘贴也要放在分组内。
- 离屏窗口无法模拟 PDFView 自己的拖动跟踪，拖选与拖放需真机确认；瞬态气泡在非活动应用中不显示，可把控制器放进普通窗口截图。
- 截图用 `bitmapImageRepForCachingDisplay` + `cacheDisplay`；`NSHostingView` 坐标翻转（顶部 y = 0）。
- SwiftUI 运行时警告只进系统日志：`/usr/bin/log stream --predicate 'process == "…" AND eventMessage CONTAINS "Publishing changes"'`（zsh 中 `log` 是内建命令；计数时别把日志头一行算进去）。
- 要测试菜单、标签页等需真实 SwiftUI 场景的行为，用应用自身的 `@main` 入口，用 `open -W -n --stdout … P.app` 启动。
