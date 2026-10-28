import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { KeyboardAvoidMode, window } from '@kit.ArkUI';

const TAG = 'WordAtlas';
const LOG_DOMAIN = 0x0000;

/**
 * 标准 Stage 模型入口 UIAbility：仅负责把窗口加载到 WebHost 页面，
 * 其余生命周期按惯例留空实现。
 */
export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(LOG_DOMAIN, TAG, 'onCreate');
  }

  onDestroy(): void {
    hilog.info(LOG_DOMAIN, TAG, 'onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(LOG_DOMAIN, TAG, 'onWindowStageCreate');
    windowStage.loadContent('pages/WebHost', (err) => {
      if (err.code) {
        hilog.error(LOG_DOMAIN, TAG, 'loadContent failed, code=%{public}d', err.code);
        return;
      }
      // 键盘弹出时不做任何布局避让（键盘直接覆盖页面）：
      // 页内所有输入框都在屏幕上半区，无需避让；避让动画正是搜索框闪动的来源。
      // 必须在 loadContent 之后调用（UI 上下文就绪），且失败不致命。
      try {
        windowStage.getMainWindowSync().getUIContext()
          .setKeyboardAvoidMode(KeyboardAvoidMode.NONE);
        hilog.info(LOG_DOMAIN, TAG, 'keyboard avoid mode set to NONE');
      } catch (e) {
        const err2 = e as BusinessError;
        hilog.error(LOG_DOMAIN, TAG, 'setKeyboardAvoidMode failed: %{public}d %{public}s', err2.code, err2.message);
      }
      hilog.info(LOG_DOMAIN, TAG, 'loadContent ok');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(LOG_DOMAIN, TAG, 'onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(LOG_DOMAIN, TAG, 'onForeground');
  }

  onBackground(): void {
    hilog.info(LOG_DOMAIN, TAG, 'onBackground');
  }
}
