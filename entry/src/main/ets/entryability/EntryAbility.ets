import { UIAbility, AbilityConstant, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    console.info('[ClawdBot] EntryAbility onCreate');
    // Initialize AppStorage keys for share data (must exist before @StorageLink binds)
    AppStorage.setOrCreate<number>('share_timestamp', 0);
    AppStorage.setOrCreate<string>('share_text', '');
    AppStorage.setOrCreate<string>('share_uri', '');
    AppStorage.setOrCreate<string>('share_uris', '');  // JSON array of URIs for multi-image
    AppStorage.setOrCreate<string>('share_type', '');
    this.handleShareWant(want);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    console.info('[ClawdBot] EntryAbility onNewWant');
    this.handleShareWant(want);
  }

  private looksLikeImageUri(s: string): boolean {
    let lower = s.toLowerCase();
    return lower.endsWith('.jpg') || lower.endsWith('.jpeg') || lower.endsWith('.png') ||
      lower.endsWith('.gif') || lower.endsWith('.webp') || lower.endsWith('.bmp') ||
      lower.indexOf('/photo/') >= 0 || lower.indexOf('/image/') >= 0 || lower.indexOf('/screenshot') >= 0;
  }

  private handleShareWant(want: Want): void {
    if (want.action !== 'ohos.want.action.sendData') {
      return;
    }
    console.info(`[ClawdBot] Share intent received: uri=${want.uri ?? ''} type=${want.type ?? ''}`);
    if (want.parameters) {
      console.info(`[ClawdBot] Share params keys: [${Object.keys(want.parameters).join(',')}]`);
      let paramKeys = Object.keys(want.parameters);
      for (let i = 0; i < Math.min(paramKeys.length, 8); i++) {
        let key = paramKeys[i];
        let val = want.parameters[key];
        console.info(`[ClawdBot] param "${key}" typeof=${typeof val} val=${String(val).substring(0, 200)}`);
      }
    }

    let shareText = '';
    let shareUri = want.uri ?? '';
    let shareType = 'text'; // default

    // 1. Determine share type from want.type MIME type
    let mimeType = (want.type ?? '').toLowerCase();
    if (mimeType.startsWith('image/') || mimeType.startsWith('image')) {
      shareType = 'image';
    } else if (mimeType.length > 0 && !mimeType.startsWith('text/') && !mimeType.startsWith('text')) {
      shareType = 'file';
    }

    // 2. Also check mime-type parameter (HarmonyOS share panel puts it here)
    if (shareType === 'text' && want.parameters) {
      let mimeParam = String(want.parameters['mime-type'] ?? '').toLowerCase();
      console.info(`[ClawdBot] mime-type param: "${mimeParam}"`);
      if (mimeParam.startsWith('image/') || mimeParam === 'image') {
        shareType = 'image';
      }
    }

    // 3. Detect image from want.uri pattern
    if (shareType !== 'image' && shareUri.length > 0 && this.looksLikeImageUri(shareUri)) {
      shareType = 'image';
      console.info('[ClawdBot] Detected image from want.uri pattern');
    }

    // 4. Check ability.params.stream for image URIs (Gallery shares put URIs here, not in want.uri)
    //    NOTE: Want.parameters values are Object type in ArkTS, typeof won't return 'string'
    //    Must use String() conversion. For multiple images, value may be an Array.
    let imageUris: string[] = [];
    if (want.parameters) {
      let streamRaw = want.parameters['ability.params.stream'];
      if (streamRaw !== undefined && streamRaw !== null) {
        // Try as array first (multiple images)
        if (Array.isArray(streamRaw)) {
          for (let item of (streamRaw as Object[])) {
            let s = String(item);
            if (s.length > 0 && s !== 'undefined' && !s.startsWith('[object')) {
              imageUris.push(s);
            }
          }
          console.info(`[ClawdBot] ability.params.stream is array, ${imageUris.length} URIs`);
        } else {
          let s = String(streamRaw);
          if (s.length > 0 && s !== 'undefined' && s !== 'null' && !s.startsWith('[object')) {
            // Could be comma-separated for multiple
            if (s.indexOf(',file://') >= 0) {
              let parts = s.split(',');
              for (let p of parts) {
                let trimmed = p.trim();
                if (trimmed.length > 0) {
                  imageUris.push(trimmed);
                }
              }
            } else {
              imageUris.push(s);
            }
          }
        }
        console.info(`[ClawdBot] ability.params.stream URIs: ${imageUris.length}`);
        for (let i = 0; i < Math.min(imageUris.length, 5); i++) {
          console.info(`[ClawdBot] URI[${i}]: ${imageUris[i].substring(0, 100)}`);
        }
      }

      // Set shareUri from first URI if not already set
      if (shareUri.length === 0 && imageUris.length > 0) {
        shareUri = imageUris[0];
      }

      // Detect image type from URIs
      if (shareType !== 'image' && imageUris.length > 0) {
        for (let u of imageUris) {
          if (this.looksLikeImageUri(u)) {
            shareType = 'image';
            console.info('[ClawdBot] Detected image from ability.params.stream URI pattern');
            break;
          }
        }
      }

      // Also check systemShare.datasource.uri
      let dsUri = String(want.parameters['systemShare.datasource.uri'] ?? '');
      if (dsUri.length > 0 && dsUri !== 'undefined' && dsUri !== 'null' && !dsUri.startsWith('[object')) {
        console.info(`[ClawdBot] systemShare.datasource.uri = "${dsUri.substring(0, 100)}"`);
        if (shareUri.length === 0) {
          shareUri = dsUri;
        }
        if (shareType !== 'image' && this.looksLikeImageUri(dsUri)) {
          shareType = 'image';
        }
      }
    }

    // 5. Only extract text from parameters for text shares
    if (shareType === 'text' && want.parameters) {
      let params = want.parameters;
      let keys: string[] = ['shareText', 'text', 'content', 'shareContent'];
      for (let key of keys) {
        if (params[key] !== undefined && params[key] !== null) {
          let s = String(params[key]);
          if (s.length > 0 && s !== 'undefined' && s !== 'null' && !s.startsWith('[object') &&
              !s.startsWith('file://') && !s.startsWith('content://') && !s.startsWith('datashare://')) {
            shareText = s;
            break;
          }
        }
      }
    }

    // 6. If we have a URI but no text, and it's still 'text' type, treat as file
    if (shareText.length === 0 && shareUri.length > 0 && shareType === 'text') {
      shareType = 'file';
    }

    console.info(`[ClawdBot] Share data: type=${shareType} textLen=${shareText.length} uris=${imageUris.length} uri=${shareUri.substring(0, 100)}`);

    // Store in AppStorage for ChatPage to consume
    AppStorage.setOrCreate<string>('share_text', shareText);
    AppStorage.setOrCreate<string>('share_uri', shareUri);
    AppStorage.setOrCreate<string>('share_uris', imageUris.length > 0 ? JSON.stringify(imageUris) : '');
    AppStorage.setOrCreate<string>('share_type', shareType);
    AppStorage.setOrCreate<number>('share_timestamp', Date.now());
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
