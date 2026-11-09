import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const DOMAIN = 0x0000;

export default class MainAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, "HPVPlayer", "%{public}s", "Ability onCreate");
    // 调试入口: aa start ... --ps hpv.addSource '<MediaSource JSON>'
    // 页面侧(Index)消费后自动添加来源, 便于 adb/hdc 自动化测试
    const raw = want.parameters?.['hpv.addSource'];
    if (typeof raw === 'string' && raw.length > 0) {
      AppStorage.setOrCreate('hpvAddSource', raw);
      hilog.info(DOMAIN, "HPVPlayer", "debug addSource pending");
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, "HPVPlayer", "%{public}s", "Ability onDestroy");
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, "HPVPlayer", "%{public}s", "Ability onWindowStageCreate");

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, "HPVPlayer", "Failed to load the content. Cause: %{public}s", JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, "HPVPlayer", "Succeeded in loading the content.");
    });

    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, "HPVPlayer", "Failed to set colorMode. Cause: %{public}s", JSON.stringify(err));
    }
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, "HPVPlayer", "%{public}s", "Ability onWindowStageDestroy");
  }

  onForeground(): void {
    hilog.info(DOMAIN, "HPVPlayer", "%{public}s", "Ability onForeground");
  }

  onBackground(): void {
    hilog.info(DOMAIN, "HPVPlayer", "%{public}s", "Ability onBackground");
  }
}
