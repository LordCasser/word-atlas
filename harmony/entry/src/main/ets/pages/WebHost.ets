/**
 * WebHost —— word-atlas 离线 HAP 壳页面（本壳工程的核心）。
 *
 * 核心机制：
 * 1. 虚拟域静态服务器：以 https://local.word-atlas.internal 加载页面，
 *    onInterceptRequest 把该域全部请求同步映射到 rawfile（www/<path>，
 *    特例 bootstrap.html）。本应用不申请任何权限（无 INTERNET），
 *    虚拟域请求必须同步返回本地响应，绝不返回 null（返回 null 会真发网络请求而失败）。
 * 2. 外链/新窗口改道系统浏览器；confirm() 接原生 AlertDialog；
 *    下载接管到 filesDir/exports/；文件选择器接 DocumentViewPicker。
 * 3. localStorage 快照层：启动由 bootstrap.html 经 HarmonyShell.readBackup() 回灌；
 *    运行中（onPageEnd / 前台 60s 定时 / 退出前）把 word-atlas:* 键写入
 *    filesDir/word-atlas/backup.json。ArkWeb 的 localStorage 落在 cache 层、
 *    无持久化承诺，此双保险是学习进度耐久性的产品核心承诺。
 *
 * 永不可变更的三条不变量（详见 harmony/README.md）：
 * bundleName com.wordatlas.hap / 签名证书 / 虚拟域名 local.word-atlas.internal。
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { webview } from '@kit.ArkWeb';
import { textToSpeech } from '@kit.CoreSpeechKit';

const TAG = 'WordAtlas';
const LOG_DOMAIN = 0x0000;

/** 虚拟域名：永不可变更（ArkWeb 的 localStorage 按“应用+源”隔离，变更即清空用户进度）。 */
const VIRTUAL_ORIGIN = 'https://local.word-atlas.internal';

const LOCAL_STORAGE_PREFIX = 'word-atlas:';
const BACKUP_DIR_NAME = 'word-atlas';
const BACKUP_FILE_NAME = 'backup.json';
const EXPORTS_DIR_NAME = 'exports';
const SNAPSHOT_INTERVAL_MS = 60 * 1000;
const DOUBLE_BACK_INTERVAL_MS = 2000;

/**
 * web 调试开关：仅本地真机联调时临时改为 true（hdc shell + chrome://inspect），
 * 发版构建必须保持 false。
 */
const isDebug = false;

/**
 * 注入页面的原生桥对象（javaScriptProxy 的 object）。
 * 用 ArkTS 类实例而非对象字面量：ArkTS 严格模式不允许未类型化对象字面量。
 */
class HarmonyShellBridge {
  private backupJson: string = '';

  setBackupJson(json: string): void {
    this.backupJson = json;
  }

  /** bootstrap.html 启动时同步调用，返回上次快照的 JSON 文本（无则空串）。 */
  readBackup(): string {
    return this.backupJson;
  }

  /**
   * 原生 TTS 朗读（Core Speech Kit）。立即返回 requestId，结果经 window.__waTtsDone(id, ok) 回调。
   * 引擎懒创建；失败也回调 ok=false，由网页侧决定降级。
   */
  ttsSpeak(text: string, rate: number): string {
    const safeText = text ?? '';
    const safeRate = rate > 0 ? rate : 1;
    return tts.speak(safeText, safeRate);
  }

  /** 停止原生 TTS 播放。 */
  ttsStop(): void {
    tts.stop();
  }
}

/**
 * Core Speech Kit TTS 引擎封装（API 26 / @kit.CoreSpeechKit）。
 * 引擎全进程最多 3 个实例，故模块级单例、懒创建、常驻（随应用进程销毁）。
 * 引擎仅支持 zh-CN / en-US：英式发音降级为美式音色（VERIFY: 真机音色确认）。
 */
class TtsEngineBox {
  private engine: textToSpeech.TextToSpeechEngine | null = null;
  private creating: Promise<boolean> | null = null;
  private seq: number = 0;
  /** 播放结束/失败回调（由 WebHost 注入，转发回网页 __waTtsDone）。 */
  onDone: ((id: string, ok: boolean) => void) | null = null;

  /**
   * 引擎创建参数候选链：d.ts 只要求 language/person/online，不枚举合法 person 值，
   * 不同设备引擎接受度不同（模拟器实测 person:0 被拒 1002300003），逐个降级尝试。
   */
  private candidates(): textToSpeech.CreateEngineParams[] {
    const mk = (language: string, person: number, online: number): textToSpeech.CreateEngineParams => {
      return { language: language, person: person, online: online };
    };
    return [mk('en-US', 0, 1), mk('en-US', 1, 0), mk('en-US', 0, 0), mk('zh-CN', 0, 1), mk('en-US', 1, 1)];
  }

  /** 懒创建引擎；逐候选降级，全部失败后可重试。 */
  ensure(): Promise<boolean> {
    if (this.engine) {
      return Promise.resolve(true);
    }
    if (!this.creating) {
      this.creating = this.tryCreate(this.candidates(), 0);
    }
    return this.creating;
  }

  private tryCreate(candidates: textToSpeech.CreateEngineParams[], index: number): Promise<boolean> {
    if (index >= candidates.length) {
      hilog.error(LOG_DOMAIN, TAG, 'tts createEngine failed: all %{public}d param candidates rejected', candidates.length);
      this.creating = null; // 允许下次重试（引擎可能稍后可用）。
      return Promise.resolve(false);
    }
    const params = candidates[index];
    return textToSpeech.createEngine(params)
      .then((engine: textToSpeech.TextToSpeechEngine): boolean => {
        const listener: textToSpeech.SpeakListener = {
          onStart: (_requestId: string, _response: textToSpeech.StartResponse): void => {
          },
          onComplete: (requestId: string, _response: textToSpeech.CompleteResponse): void => {
            this.onDone?.(requestId, true);
          },
          onStop: (requestId: string, _response: textToSpeech.StopResponse): void => {
            this.onDone?.(requestId, true);
          },
          onError: (requestId: string, errorCode: number, errorMessage: string): void => {
            hilog.error(LOG_DOMAIN, TAG, 'tts onError %{public}d %{public}s', errorCode, errorMessage);
            this.onDone?.(requestId, false);
          }
        };
        engine.setListener(listener);
        this.engine = engine;
        hilog.info(LOG_DOMAIN, TAG, 'tts engine created (lang=%{public}s person=%{public}d online=%{public}d)',
          params.language, params.person, params.online);
        return true;
      })
      .catch((err: BusinessError): Promise<boolean> => {
        hilog.error(LOG_DOMAIN, TAG, 'tts candidate %{public}d rejected: %{public}s', index, `${err.code} ${err.message}`);
        return this.tryCreate(candidates, index + 1);
      });
  }

  /** 发起朗读：生成 requestId，引擎就绪后合成播放；结果经 onDone 回调。 */
  speak(text: string, rate: number): string {
    this.seq += 1;
    const id = `wa-tts-${this.seq}`;
    const clamped = Math.min(2, Math.max(0.5, rate));
    this.ensure().then((ok: boolean) => {
      if (!ok) {
        this.onDone?.(id, false);
        return;
      }
      this.startSpeak(id, text, clamped);
    });
    return id;
  }

  private startSpeak(id: string, text: string, rate: number): void {
    const engine = this.engine;
    if (!engine) {
      this.onDone?.(id, false);
      return;
    }
    const extra: Record<string, Object> = { 'speed': rate };
    const params: textToSpeech.SpeakParams = { requestId: id, extraParams: extra };
    try {
      engine.speak(text, params);
    } catch (e) {
      // speed 等参数不被当前引擎接受时，去参重试一次。
      const fallback: textToSpeech.SpeakParams = { requestId: id };
      try {
        engine.speak(text, fallback);
      } catch (e2) {
        hilog.error(LOG_DOMAIN, TAG, 'tts speak failed: %{public}s', this.errText(e2));
        this.onDone?.(id, false);
      }
    }
  }

  stop(): void {
    try {
      this.engine?.stop();
    } catch (e) {
      hilog.error(LOG_DOMAIN, TAG, 'tts stop failed: %{public}s', this.errText(e));
    }
  }

  private errText(e: Object): string {
    const err = e as BusinessError;
    return `${err.code} ${err.message}`;
  }
}

const tts = new TtsEngineBox();

@Entry
@Component
struct WebHost {
  controller: webview.WebviewController = new webview.WebviewController();
  delegate: webview.WebDownloadDelegate = new webview.WebDownloadDelegate();
  private bridge: HarmonyShellBridge = new HarmonyShellBridge();
  private lastBackPressTime: number = 0;
  private snapshotTimerId: number = -1;
  private lastDownloadPath: string = '';

  aboutToAppear(): void {
    // 启动快照回灌：读出备份交给 bootstrap.html（在拦截器中特例提供）。
    this.bridge.setBackupJson(this.readBackupSync());
    // TTS 结果转发回网页（window.__waTtsDone）。
    tts.onDone = (id: string, ok: boolean): void => {
      try {
        this.controller.runJavaScript(`window.__waTtsDone && window.__waTtsDone('${id}', ${ok ? 'true' : 'false'})`);
      } catch (e) {
        hilog.error(LOG_DOMAIN, TAG, 'tts done notify failed: %{public}s', this.errText(e));
      }
    };
    try {
      // VERIFY: setWebDebuggingAccess 为 WebviewController 的静态方法（官方文档已核，API 9+）。
      webview.WebviewController.setWebDebuggingAccess(isDebug);
    } catch (e) {
      hilog.error(LOG_DOMAIN, TAG, 'setWebDebuggingAccess failed: %{public}s', this.errText(e));
    }
    // 前台 60s 定时快照；aboutToDisappear 清除。
    this.snapshotTimerId = setInterval(() => {
      this.snapshotLocalStorage('foreground-timer');
    }, SNAPSHOT_INTERVAL_MS);
    this.registerDownloadDelegate();
  }

  aboutToDisappear(): void {
    if (this.snapshotTimerId >= 0) {
      clearInterval(this.snapshotTimerId);
      this.snapshotTimerId = -1;
    }
  }

  /** 下载接管：导出备份与分享卡全靠它。 */
  private registerDownloadDelegate(): void {
    this.delegate.onBeforeDownload((item: webview.WebDownloadItem) => {
      const exportsDir = `${this.filesDir()}/${EXPORTS_DIR_NAME}`;
      this.ensureDirSync(exportsDir);
      const targetPath = `${exportsDir}/${item.getSuggestedFileName()}`;
      this.lastDownloadPath = targetPath;
      // 注意：blob: URL 下载是否会到达 delegate 属未验证项，真机验证清单见 harmony/README.md。
      hilog.info(LOG_DOMAIN, TAG, 'onBeforeDownload -> %{public}s', targetPath);
      item.start(targetPath);
    });
    this.delegate.onDownloadFinish((_item: webview.WebDownloadItem) => {
      hilog.info(LOG_DOMAIN, TAG, 'onDownloadFinish: %{public}s', this.lastDownloadPath);
      this.getUIContext().getPromptAction().showToast({
        message: `已保存: ${this.lastDownloadPath}`,
        duration: 3000
      });
    });
    this.delegate.onDownloadFailed((item: webview.WebDownloadItem) => {
      hilog.error(LOG_DOMAIN, TAG, 'onDownloadFailed guid=%{public}s path=%{public}s',
        item.getGuid(), this.lastDownloadPath);
      this.getUIContext().getPromptAction().showToast({ message: '保存失败', duration: 3000 });
    });
  }

  /**
   * 返回键：Web 可后退则后退；否则 2s 内二次按退到后台，首次提示。
   */
  onBackPress(): boolean {
    try {
      if (this.controller.accessBackward()) {
        this.controller.backward();
        return true;
      }
    } catch (e) {
      hilog.error(LOG_DOMAIN, TAG, 'accessBackward failed: %{public}s', this.errText(e));
    }
    const now = Date.now();
    if (this.lastBackPressTime > 0 && now - this.lastBackPressTime <= DOUBLE_BACK_INTERVAL_MS) {
      // 退出路径：尽力而为地补一次快照（异步，可能来不及落盘；前台 60s 定时器兜底）。
      this.snapshotLocalStorage('exit');
      const context = getContext(this) as common.UIAbilityContext;
      context.moveAbilityToBackground()
        .then(() => {
          hilog.info(LOG_DOMAIN, TAG, 'moved to background');
        })
        .catch((err: BusinessError) => {
          hilog.error(LOG_DOMAIN, TAG, 'moveAbilityToBackground failed: %{public}s', this.errText(err));
        });
      return true;
    }
    this.lastBackPressTime = now;
    this.getUIContext().getPromptAction().showToast({ message: '再按一次退出', duration: 1500 });
    return true;
  }

  build() {
    Column() {
      Web({ src: `${VIRTUAL_ORIGIN}/bootstrap.html`, controller: this.controller })
        .width('100%')
        .height('100%')
        .domStorageAccess(true)
        .javaScriptAccess(true)
        .mediaPlayGestureAccess(false)
        .zoomAccess(false)
        .backgroundColor('#0D1120')
        // 键盘弹出时不缩放任何视口（默认 RESIZE_CONTENT 会改 innerHeight，
        // 造成页内布局回流、搜索组件位移）。键盘直接覆盖页面；
        // 页内输入框均位于屏幕上半区，不会被键盘遮挡。
        .keyboardAvoidMode(WebKeyboardAvoidMode.OVERLAYS_CONTENT)
        // target=_blank 走新窗口流程需开启 multiWindowAccess（官方文档：使能后 onWindowNew 才通知）。
        .multiWindowAccess(true)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .javaScriptProxy({
          name: 'HarmonyShell',
          object: this.bridge,
          methodList: ['readBackup', 'ttsSpeak', 'ttsStop'],
          controller: this.controller
        })
        .onControllerAttached(() => {
          this.controller.setDownloadDelegate(this.delegate);
          hilog.info(LOG_DOMAIN, TAG, 'web controller attached');
        })
        .onInterceptRequest((event) => {
          if (!event) {
            // 拿不到请求对象时按 404 处理，绝不能放行内核（无网络权限，放行即 ERR_FAILED）。
            hilog.error(LOG_DOMAIN, TAG, 'onInterceptRequest: empty event, serve 404');
            return this.notFoundResponse();
          }
          const url = event.request.getRequestUrl();
          if (!url.startsWith(`${VIRTUAL_ORIGIN}/`)) {
            // 非虚拟域：放行内核默认处理（外链已在 onLoadIntercept 改道系统浏览器）。
            return null;
          }
          // 虚拟域请求：同步返回本地响应，此分支永不返回 null。
          return this.serveVirtual(url);
        })
        .onLoadIntercept((event) => {
          if (!event || !event.data) {
            hilog.error(LOG_DOMAIN, TAG, 'onLoadIntercept: empty event, allow');
            return false;
          }
          const url = event.data.getRequestUrl();
          const isHttp = url.startsWith('http://') || url.startsWith('https://');
          if (isHttp && !url.startsWith(VIRTUAL_ORIGIN)) {
            // 外部 http/https 链接改道系统浏览器，阻止 Web 内加载。
            this.openInSystemBrowser(url);
            return true;
          }
          return false;
        })
        .onWindowNew((event) => {
          // 官方 API（V13 参考已核）：OnWindowNewEvent { isAlert, isUserTrigger, targetUrl, handler }。
          // Spec 假设的 NewWindowInfo.getUrl() 访问器不存在，改用 event.targetUrl；
          // 拒绝创建新窗口必须调 handler.setWebController(null)，否则 render 进程阻塞。
          if (!event) {
            return;
          }
          const targetUrl = event.targetUrl;
          hilog.info(LOG_DOMAIN, TAG, 'onWindowNew target=%{public}s -> system browser', targetUrl);
          if (targetUrl.startsWith('http://') || targetUrl.startsWith('https://')) {
            this.openInSystemBrowser(targetUrl);
          }
          event.handler.setWebController(null);
        })
        .onConfirm((event) => {
          // 原生 confirm() 接线：不处理时 ArkWeb 默认不弹框、confirm() 静默失败。
          if (!event) {
            return false;
          }
          AlertDialog.show({
            message: event.message,
            primaryButton: {
              value: '确认',
              action: () => {
                event.result.handleConfirm();
              }
            },
            secondaryButton: {
              value: '取消',
              action: () => {
                event.result.handleCancel();
              }
            }
          });
          // 必须返回 true 表示已接管。
          return true;
        })
        .onShowFileSelector((event) => {
          // 导入备份：<input type="file"> 由原生 DocumentViewPicker 接管。
          if (!event) {
            return false;
          }
          const opts = new picker.DocumentSelectOptions();
          new picker.DocumentViewPicker(getContext(this)).select(opts)
            .then((uris: Array<string>) => {
              if (uris && uris.length > 0) {
                event.result.handleFileList([uris[0]]);
              } else {
                // VERIFY: FileSelectorResult 公开 API 仅有 handleFileList（官方文档已核，无 handleCancel）。
                // Spec 要求的 handleCancel() 用空数组取消语义替代。
                event.result.handleFileList([]);
              }
            })
            .catch(() => {
              event.result.handleFileList([]);
            });
          // 必须返回 true 表示应用接管；必须以 handleFileList 收尾，否则前端流程挂起。
          return true;
        })
        .onPageEnd((event) => {
          const url = event ? event.url : '';
          hilog.info(LOG_DOMAIN, TAG, 'onPageEnd: %{public}s', url);
          this.snapshotLocalStorage('onPageEnd');
        })
        .onConsole((event) => {
          if (event) {
            hilog.info(LOG_DOMAIN, TAG, '[console] %{public}s', event.message.getMessage());
          }
          return false;
        })
        .onErrorReceive((event) => {
          if (event) {
            hilog.error(LOG_DOMAIN, TAG, '[weberror] %{public}s code=%{public}d info=%{public}s',
              event.request.getRequestUrl(), event.error.getErrorCode(), event.error.getErrorInfo());
          }
        });
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0D1120');
  }

  /**
   * 虚拟域静态服务器：path -> rawfile 映射 + 安全校验。
   * 永远返回一个响应（200/404），不返回 null。
   */
  private serveVirtual(url: string): WebResourceResponse {
    let path = url.substring(VIRTUAL_ORIGIN.length);
    const query = path.indexOf('?');
    if (query >= 0) {
      path = path.substring(0, query);
    }
    const hash = path.indexOf('#');
    if (hash >= 0) {
      path = path.substring(0, hash);
    }
    let decoded = '';
    try {
      decoded = decodeURIComponent(path);
    } catch (e) {
      hilog.error(LOG_DOMAIN, TAG, 'bad percent-encoding: %{public}s', path);
      return this.notFoundResponse();
    }
    if (decoded === '' || decoded === '/') {
      decoded = '/index.html';
    }
    if (decoded === '/bootstrap.html') {
      // 壳私有启动页：rawfile 根，不在 www/ 内。
      return this.serveRawFile('bootstrap.html');
    }
    if (this.hasTraversalSegment(decoded)) {
      hilog.error(LOG_DOMAIN, TAG, 'blocked path traversal: %{public}s', decoded);
      return this.notFoundResponse();
    }
    return this.serveRawFile(`www${decoded}`);
  }

  /** 解码后的路径含 ".." 段即拒绝（防 rawfile 目录穿越）。 */
  private hasTraversalSegment(path: string): boolean {
    const segments = path.split('/');
    for (const segment of segments) {
      if (segment === '..') {
        return true;
      }
    }
    return false;
  }

  /** 读 rawfile 构造 200 响应；未命中/异常一律 404（空 body）。 */
  private serveRawFile(rawfilePath: string): WebResourceResponse {
    try {
      const data: Uint8Array = getContext(this).resourceManager.getRawFileContentSync(rawfilePath);
      // setResponseData 需要 ArrayBuffer：从 Uint8Array 底层 buffer 切出有效区间。
      const body: ArrayBuffer = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
      const mimeType = this.mimeFor(rawfilePath);
      const resp = new WebResourceResponse();
      resp.setResponseCode(200);
      resp.setReasonMessage('OK');
      resp.setResponseMimeType(mimeType);
      resp.setResponseData(body);
      if (this.isTextMime(mimeType)) {
        // 仅文本类型设 encoding；二进制类型绝不设（会导致音视频播放失败）。
        resp.setResponseEncoding('utf-8');
      }
      // 同源无需 CORS 头；音频等请求带 Range 时一律忽略，200 全量返回（文件均值 18-27KB，既定决策）。
      resp.setResponseHeader([{ headerKey: 'Cache-Control', headerValue: 'no-cache' }]);
      resp.setResponseIsReady(true);
      return resp;
    } catch (e) {
      hilog.error(LOG_DOMAIN, TAG, 'rawfile miss: %{public}s (%{public}s)', rawfilePath, this.errText(e));
      return this.notFoundResponse();
    }
  }

  private notFoundResponse(): WebResourceResponse {
    const resp = new WebResourceResponse();
    resp.setResponseCode(404);
    resp.setReasonMessage('Not Found');
    resp.setResponseMimeType('text/plain');
    resp.setResponseData(new ArrayBuffer(0));
    resp.setResponseIsReady(true);
    return resp;
  }

  /** MIME 按扩展名精确映射；MIME 错会导致 JS 不执行、页面白屏。 */
  private mimeFor(rawfilePath: string): string {
    const dot = rawfilePath.lastIndexOf('.');
    if (dot < 0) {
      return 'application/octet-stream';
    }
    switch (rawfilePath.substring(dot + 1).toLowerCase()) {
      case 'html':
        return 'text/html';
      case 'js':
        return 'text/javascript';
      case 'css':
        return 'text/css';
      case 'json':
        return 'application/json';
      case 'webmanifest':
        return 'application/manifest+json';
      case 'svg':
        return 'image/svg+xml';
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'webp':
        return 'image/webp';
      case 'mp3':
        return 'audio/mpeg';
      case 'mp4':
        return 'video/mp4';
      case 'woff2':
        return 'font/woff2';
      case 'woff':
        return 'font/woff';
      case 'otf':
        return 'font/otf';
      case 'txt':
        return 'text/plain';
      default:
        return 'application/octet-stream';
    }
  }

  private isTextMime(mime: string): boolean {
    return mime === 'text/html'
      || mime === 'text/javascript'
      || mime === 'text/css'
      || mime === 'application/json'
      || mime === 'application/manifest+json'
      || mime === 'image/svg+xml'
      || mime === 'text/plain';
  }

  private openInSystemBrowser(url: string): void {
    const context = getContext(this) as common.UIAbilityContext;
    context.openLink(url, { appLinkingOnly: false })
      .then(() => {
        hilog.info(LOG_DOMAIN, TAG, 'openLink ok: %{public}s', url);
      })
      .catch((err: BusinessError) => {
        hilog.error(LOG_DOMAIN, TAG, 'openLink failed: %{public}s (%{public}s)', url, this.errText(err));
      });
  }

  private filesDir(): string {
    return (getContext(this) as common.UIAbilityContext).filesDir;
  }

  private ensureDirSync(dir: string): void {
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
    } catch (e) {
      hilog.error(LOG_DOMAIN, TAG, 'mkdir failed: %{public}s (%{public}s)', dir, this.errText(e));
    }
  }

  /** 同步读取 filesDir/word-atlas/backup.json；不存在/读取失败返回空串。 */
  private readBackupSync(): string {
    const path = `${this.filesDir()}/${BACKUP_DIR_NAME}/${BACKUP_FILE_NAME}`;
    try {
      if (!fs.accessSync(path)) {
        return '';
      }
      const size = fs.statSync(path).size;
      if (size <= 0) {
        return '';
      }
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        const buffer = new ArrayBuffer(size);
        const bytesRead = fs.readSync(file.fd, buffer);
        if (bytesRead <= 0) {
          return '';
        }
        // VERIFY: decodeWithStream 在 API 12 可用（已标 deprecated，替代为 decodeToString）。
        return util.TextDecoder.create('utf-8').decodeWithStream(new Uint8Array(buffer, 0, bytesRead));
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      hilog.error(LOG_DOMAIN, TAG, 'readBackup failed: %{public}s (%{public}s)', path, this.errText(e));
      return '';
    }
  }

  /** 同步写入快照；失败仅记日志（快照失败不弹 UI）。 */
  private writeBackupSync(json: string): void {
    const dir = `${this.filesDir()}/${BACKUP_DIR_NAME}`;
    const path = `${dir}/${BACKUP_FILE_NAME}`;
    try {
      this.ensureDirSync(dir);
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, json);
      } finally {
        fs.closeSync(file);
      }
      hilog.info(LOG_DOMAIN, TAG, 'backup saved: %{public}s (%{public}d chars)', path, json.length);
    } catch (e) {
      hilog.error(LOG_DOMAIN, TAG, 'writeBackup failed: %{public}s (%{public}s)', path, this.errText(e));
    }
  }

  /** 把前端 localStorage 的 word-atlas:* 键快照为 JSON 文本并落盘。 */
  private snapshotLocalStorage(reason: string): void {
    const script = `JSON.stringify(Object.fromEntries(Object.keys(localStorage).filter(function (k) { return k.indexOf('${LOCAL_STORAGE_PREFIX}') === 0; }).map(function (k) { return [k, localStorage.getItem(k)]; })))`;
    this.controller.runJavaScript(script)
      .then((json: string) => {
        hilog.info(LOG_DOMAIN, TAG, 'snapshot(%{public}s) len=%{public}d', reason, json.length);
        if (json.length > 2) {
          // '{}'（无数据）不落盘。
          this.writeBackupSync(json);
        }
      })
      .catch((err: BusinessError) => {
        hilog.error(LOG_DOMAIN, TAG, 'snapshot(%{public}s) failed: %{public}s', reason, this.errText(err));
      });
  }

  private errText(e: Object): string {
    const err = e as BusinessError;
    return `${err.code} ${err.message}`;
  }
}
