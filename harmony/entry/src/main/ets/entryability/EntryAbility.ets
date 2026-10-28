import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

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
