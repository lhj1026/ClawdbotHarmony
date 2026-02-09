import { UIAbility, AbilityConstant, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    console.info('[ClawdBot] EntryAbility onCreate');
  }

  onDestroy(): void {
    console.info('[ClawdBot] EntryAbility onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    console.info('[ClawdBot] onWindowStageCreate');
    windowStage.loadContent('pages/Index', (err) => {
      if (err) {
        console.error('[ClawdBot] loadContent failed: ' + JSON.stringify(err));
        return;
      }
      console.info('[ClawdBot] loadContent succeeded');
    });
  }

  onWindowStageDestroy(): void {
    console.info('[ClawdBot] onWindowStageDestroy');
  }

  onForeground(): void {
    console.info('[ClawdBot] onForeground');
  }

  onBackground(): void {
    console.info('[ClawdBot] onBackground');
  }
}
