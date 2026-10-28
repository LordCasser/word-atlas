# word-atlas HarmonyOS HAP 壳工程

把 React SPA（Vite 构建产物 `dist/`）封装为**完全离线**的 HarmonyOS 应用（API 12+ / Stage 模型）。
原生壳只做一件事：用 ArkWeb 加载虚拟域 `https://local.word-atlas.internal`，并把该域的
全部请求拦截映射到 `rawfile/www/`，从而绕开 `file://` / `resource://` 协议对 `fetch()` 的同源限制。

```
HarmonyOS HAP（无任何权限，全离线）
└─ EntryAbility → pages/WebHost
   └─ Web(src = https://local.word-atlas.internal/bootstrap.html)
      ├─ onInterceptRequest  → rawfile 静态服务器（www/<path>，特例 bootstrap.html）
      ├─ onLoadIntercept / onWindowNew → 外链改道系统浏览器
      ├─ onConfirm → 原生 AlertDialog
      ├─ WebDownloadDelegate → filesDir/exports/（导出备份 / 分享卡）
      ├─ onShowFileSelector → DocumentViewPicker（导入备份）
      └─ HarmonyShell.javaScriptProxy → localStorage 快照层
```

## ⚠️ 永不可变更的三条不变量

| 不变量 | 原因 |
| --- | --- |
| `bundleName: com.wordatlas.hap` | 学习进度存 localStorage，按“应用”隔离；改包名 = 用户进度孤儿化 |
| 签名证书 | 换证书 = 换应用身份，效果同上 |
| 虚拟域名 `https://local.word-atlas.internal` | ArkWeb 的 localStorage 按“应用+源”隔离；改域名 = 清空用户进度 |

任何一条变更都会让已发布用户的本地学习进度无法迁移。确需变更必须先设计数据迁移方案，不要直接改。
（页内 `WebHost.ets` 顶部的 `VIRTUAL_ORIGIN` 常量与 `AppScope/app.json5` 的 `bundleName` 必须同步保持。）

## 前置条件

- DevEco Studio 5.x（API 12 / HarmonyOS NEXT）
- Node.js 20+
- macOS（`sync-www.sh` 使用 `shasum` / `stat -f`）

## 构建步骤

在仓库根目录执行：

```bash
npm ci
npm run build          # 产出 dist/（HTML/JS/CSS + atlas/ 数据，约 715MB）
cd harmony
./sync-www.sh          # 同步 dist -> rawfile/www/ 并做完整性校验
```

然后用 DevEco Studio 打开 `harmony/` 目录：

1. **必须先跑 `sync-www.sh` 再构建**：`rawfile/www/` 与 `AppScope/.../app_icon.png`
   都是脚本生成物（已 gitignore），缺失时工程无法构建出完整可用的 HAP；
2. 首次打开时 DevEco 会自动生成 hvigor wrapper（`hvigorw`、`hvigor/hvigor-wrapper.js` 等），
   属正常现象，按团队约定决定是否提交；
3. `File → Project Structure → Signing Configs` 配置自动/手动签名
   （根 `build-profile.json5` 的 `signingConfigs` 为空是初始状态，签名后由 IDE 回填）；
4. 连接真机，Build HAP 安装运行。

## sync-www.sh 做了什么

1. 校验 `../dist/index.html` 存在，否则报错退出；
2. `rsync -a --delete --exclude sw.js --exclude .DS_Store dist/ → entry/src/main/resources/rawfile/www/`
   ，并显式剔除 `www/sw.js`（Service Worker 不需要）；
3. 拷贝 `public/icon-512.png` → `AppScope/resources/base/media/app_icon.png` 与
   `entry/src/main/resources/base/media/icon.png`（后者仓库内有占位图，脚本会覆盖为真实图标）；
4. **完整性关卡**：对 dist（排除 sw.js/.DS_Store）与 www 分别用 `find | sort | xargs shasum`
   生成清单并 diff，不一致输出 `MISMATCH` 并 exit 1；一致则打印文件数与总字节。

## 原生壳接线（entry/src/main/ets/pages/WebHost.ets）

| 接线点 | 实现 |
| --- | --- |
| 虚拟域静态服务器 | `onInterceptRequest`：非虚拟域返回 `null` 放行；虚拟域**同步**返回 200/404，含 `..` 段拒绝、`decodeURIComponent`、`bootstrap.html` 特例、按扩展名精确 MIME（二进制不设 encoding）、忽略 Range 一律 200 全量 |
| 外链改道 | `onLoadIntercept`（http/https 且非虚拟域 → `openLink`）+ `onWindowNew`（`targetUrl` → `openLink`，`handler.setWebController(null)` 拒绝新窗口避免 render 进程阻塞） |
| confirm() | `onConfirm` → 原生 `AlertDialog.show`（确认/取消分别 `handleConfirm`/`handleCancel`），返回 `true` |
| 下载接管 | `WebDownloadDelegate`：`onBeforeDownload` 建 `filesDir/exports/` 后 `item.start()`；`onDownloadFinish`/`onDownloadFailed` toast；`onControllerAttached` 中 `setDownloadDelegate` |
| 文件选择器 | `onShowFileSelector` → `DocumentViewPicker.select()`，结果 `handleFileList([uri])`，取消/失败 `handleFileList([])`（公开 API 无 `handleCancel`），返回 `true` |
| 返回键 | `onBackPress`：Web 可后退则后退；否则 2 秒内二次按 → `moveAbilityToBackground()`；首次 toast「再按一次退出」 |
| web 调试 | `setWebDebuggingAccess(isDebug)`，`isDebug` 常量默认 `false`，联调时临时改 `true` |

## localStorage 快照层（进度耐久性双保险）

ArkWeb 的 localStorage 落在 el2 cache 层，**没有持久化承诺**（可能被系统清理或签名变更清零）。
壳侧双保险：

- **回灌（每次启动）**：`rawfile/bootstrap.html` 等待 `HarmonyShell` 桥（最多 1s）→
  `readBackup()` 同步取回上次快照 → 仅回灌 ArkWeb 侧尚不存在的键 → `location.replace('index.html')`；
- **快照（运行中）**：`runJavaScript` 提取 `word-atlas:` 前缀键写入
  `filesDir/word-atlas/backup.json`。触发点：`onPageEnd`、前台 60s 定时、双击返回退出前（尽力而为）。
  快照失败仅 hilog，不打扰用户。

## 真机验证清单

- [ ] 冷启动：启动页 → 首页正常渲染，无白屏（`hilog | grep WordAtlas` 应看到 controller attached / onPageEnd）；
- [ ] 同源 `fetch()`：`/atlas/index.json`、`/atlas/entries/N.json` 数据加载成功；
- [ ] `<img>`/`<audio>`/`<video>` 媒体正常加载与播放（验证二进制响应未设 encoding）；
- [ ] hash 路由切换正常，页面间返回键走 Web 后退；
- [ ] 学习进度：学习若干词条 → 杀进程重开 → 进度仍在（验证快照 + 回灌链路）；
- [ ] 清 App 缓存（或重装同签名包）后启动 → 进度从 `backup.json` 回灌（耐久性承诺）；
- [ ] 导出备份：前端导出 → toast「已保存: /data/storage/.../exports/...」→ 文件确实存在；
- [ ] **blob: URL 导出是否会触发下载 delegate（未验证项）**：观察 `onBeforeDownload` 日志是否出现；
- [ ] 导入备份：前端导入 → 弹出系统文件选择器 → 选择文件后前端流程正常继续（无挂起）；
- [ ] 页内 `confirm()` 弹出原生 AlertDialog，确认/取消均正确返回；
- [ ] 页内外链/`target=_blank` 链接跳系统浏览器，App 内不加载外部站点；
- [ ] 飞行模式下全功能可用（应用未申请 INTERNET，任何请求不得依赖网络）；
- [ ] 软键盘弹出/收起时输入框不被安全区遮挡（`expandSafeArea` 行为，未验证项）;
- [ ] `navigator.share` 行为确认（未验证项）；
- [ ] 星图页面滚动流畅度（WebSchemeHandler 升级触发器：仅当滚动掉帧时才考虑实现，见下）。

## 已知未验证项与升级路径

ArkTS 已在 DevEco Studio 26（API 26 SDK）下编译通过并在模拟器验证启动链路（2026-10）：
页面加载、虚拟域拦截、bootstrap 回灌、index.html 渲染均正常。
以下 API 用法仍以真机验证为准，代码中相应位置带 `// VERIFY:` 注释：

- **blob: URL 下载**：`<a download href=blob:...>` 是否到达 `WebDownloadDelegate` 未验证；
  delegate 回调里已埋好 `onBeforeDownload` 日志用于真机确认。若 blob 下载不可达，
  升级路径是在原生侧做 blob 转存 shim（`javaScriptProxy` + `fs` 写文件），本期未实现；
- **`FileSelectorResult.handleCancel()`**：公开 API 仅有 `handleFileList`，取消用空数组语义，
  真机需确认取消后前端 `<input type=file>` 流程正常收尾；
- **软键盘**：`expandSafeArea` 全屏下键盘避让表现需真机确认；
- **`navigator.share`**：系统分享面板可用性未验证；
- **无录音例句的朗读**：ArkWeb 无 TTS 语音（speechSynthesis 零 voices），无录音的例句
  （如多数词条的第二例句）点击后提示「此例句暂无朗读录音」。若产品要求这类例句可听，
  升级路径是原生侧接 Core Speech Kit 的 textToSpeech，经 HarmonyShell 桥暴露给网页；
- **WebSchemeHandler**：性能更强的本地协议方案，**升级触发器 = 星图页面滚动掉帧**。
  仅在该现象真实出现时再实现，当前 `onInterceptRequest` 方案已满足需求（既定决策）。

## 工程结构

```
harmony/
├─ .gitignore                          # 忽略 www/（715MB）、构建产物、脚本生成物
├─ README.md
├─ sync-www.sh                         # dist -> rawfile/www 同步 + shasum 完整性关卡
├─ AppScope/
│  ├─ app.json5                        # bundleName com.wordatlas.hap（永不变）
│  ├─ resources/base/element/string.json # app_name（label 必须走 $string: 引用，裸中文会被 schema 拒绝）
│  └─ resources/base/media/app_icon.png   # 脚本生成（gitignore）
├─ build-profile.json5                 # compatibleSdkVersion 5.0.0(12)，无签名配置初始态
├─ hvigor/hvigor-config.json5          # modelVersion 5.0.0
├─ hvigorfile.ts                       # 工程级构建脚本（appTasks）——DevEco 识别/构建必需，缺失会报“不包含项目”
├─ oh-package.json5
└─ entry/
   ├─ build-profile.json5
   ├─ hvigorfile.ts                    # 模块级构建脚本（hapTasks）——同上，每个模块必需
   ├─ oh-package.json5
   └─ src/main/
      ├─ module.json5                  # requestPermissions: []，永不加权限（尤其 INTERNET）
      ├─ ets/
      │  ├─ entryability/EntryAbility.ets
      │  └─ pages/WebHost.ets          # 核心接线
      └─ resources/
         ├─ rawfile/bootstrap.html     # 壳私有启动页（快照回灌），不在 www/ 内
         └─ base/
            ├─ element/string.json     # Module_desc / EntryAbility_desc / EntryAbility_label
            ├─ element/color.json      # start_window_background #0D1120
            ├─ media/icon.png          # 占位图标，sync-www.sh 覆盖为真实图标
            └─ profile/main_pages.json # 页面注册 {"src":["pages/WebHost"]}
                                       # （Stage 模型页面注册文件的平台约定名为 main_pages.json）
```

## 禁止事项（代码 review 检查点）

- 不给 `module.json5` 加任何权限（尤其 `ohos.permission.INTERNET`）；
- `onInterceptRequest` 对虚拟域请求永不返回 `null`；不删 `decodeURIComponent`、`..` 防护、404 fallback；
- 二进制 MIME 响应不设 `setResponseEncoding`；Range 不实现 206（既定决策）；
- 所有 `.json5` 同时是严格合法 JSON（可用 `node -e "JSON.parse(...)"` 校验）。
