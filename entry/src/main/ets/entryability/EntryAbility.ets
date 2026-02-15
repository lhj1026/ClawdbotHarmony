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

    windowStage.getMainWindow().then((win: window.Window) => {
      // 1. Disable full-screen layout so system status bar area is reserved automatically.
      //    This prevents content from overlapping with the status bar.
      try {
        win.setWindowLayoutFullScreen(false);
        console.info('[ClawdBot] Window layout set to non-fullscreen');
      } catch (e) {
        console.warn('[ClawdBot] setWindowLayoutFullScreen failed: ' + (e as Error).message);
      }

      // 2. Set keyboard avoid mode to RESIZE (value 1) so the layout shrinks
      //    instead of the entire window shifting up (which causes status bar overlap).
      try {
        // KeyboardAvoidMode: OFFSET=0, RESIZE=1
        win.getUIContext().setKeyboardAvoidMode(1);
        console.info('[ClawdBot] Keyboard avoid mode set to RESIZE');
      } catch (e) {
        console.warn('[ClawdBot] setKeyboardAvoidMode failed: ' + (e as Error).message);
      }
    }).catch((e: Error) => {
      console.warn('[ClawdBot] getMainWindow failed: ' + e.message);
    });

    // Check login state and route accordingly
    this.getInitialPage().then((page: string) => {
      console.info('[ClawdBot] Loading page: ' + page);
      windowStage.loadContent(page, (err) => {
        if (err) {
          console.error('[ClawdBot] loadContent failed: ' + JSON.stringify(err));
          return;
        }
        console.info('[ClawdBot] loadContent succeeded: ' + page);
      });
    }).catch(() => {
      // Fallback to main page on error
      windowStage.loadContent('pages/Index', (err) => {
        if (err) {
          console.error('[ClawdBot] loadContent fallback failed: ' + JSON.stringify(err));
        }
      });
    });
  }

  private async getInitialPage(): Promise<string> {
    console.info('[ClawdBot] Loading Index directly');
    return 'pages/Index';
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
