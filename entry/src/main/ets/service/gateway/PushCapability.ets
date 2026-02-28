/**
 * PushCapability — manages Huawei Push Kit token lifecycle.
 * Obtains and stores the device push token, reports it to the Gateway,
 * and handles push notification payloads delivered via Want parameters.
 *
 * This acts as a fallback notification channel: when WebSocket is disconnected
 * (e.g. app killed in background), the Gateway can send messages via Push Kit.
 *
 * NOTE: getToken() will fail if the app is not registered in AGC (AppGallery Connect).
 * All errors are logged and swallowed — push capability is strictly best-effort.
 */
import { pushService } from '@kit.PushKit';
import { preferences } from '@kit.ArkData';
import { common, Ability } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LogService } from '../../common/LogService';

const TAG = 'PushCap';
const PREFS_NAME = 'push_prefs';
const KEY_PUSH_TOKEN = 'push_token';

export class PushCapability {
  private static instance: PushCapability | undefined = undefined;
  private log: LogService = LogService.getInstance();
  private token: string = '';
  private context: common.UIAbilityContext | undefined = undefined;
  private ability: Ability | undefined = undefined;

  /** Callback: invoked when a token is first obtained or refreshed. */
  onTokenChanged: ((token: string) => void) | undefined = undefined;

  private constructor() {}

  static getInstance(): PushCapability {
    if (!PushCapability.instance) {
      PushCapability.instance = new PushCapability();
    }
    return PushCapability.instance;
  }

  /**
   * Initialize: load stored token, register update listener, and fetch current token.
   * Call once from EntryAbility.onCreate(). Non-blocking — errors are logged and ignored.
   */
  async init(context: common.UIAbilityContext, ability?: Ability): Promise<void> {
    this.context = context;
    this.ability = ability;

    // Load previously cached token so it's available immediately
    await this.loadStoredToken();

    // Listen for token refresh (happens when the push token is rotated by HMS)
    try {
      if (!this.ability) {
        this.log.warn(TAG, 'No ability reference, skipping tokenUpdate listener');
        this.fetchToken();
        return;
      }
      pushService.on('tokenUpdate', this.ability, (newToken: string) => {
        this.log.info(TAG, `Token updated: ${newToken.substring(0, 20)}...`);
        if (newToken !== this.token) {
          this.token = newToken;
          this.saveToken(newToken);
          this.onTokenChanged?.(newToken);
        }
      });
    } catch (err) {
      this.log.warn(TAG, `pushService.on tokenUpdate failed: ${(err as Error).message}`);
    }

    // Fetch latest token asynchronously (non-blocking)
    this.fetchToken();
  }

  /** Returns the current push token, or empty string if not yet obtained. */
  getToken(): string {
    return this.token;
  }

  private fetchToken(): void {
    pushService.getToken().then((token: string) => {
      this.log.info(TAG, `Token obtained: ${token.substring(0, 20)}...`);
      if (token !== this.token) {
        this.token = token;
        this.saveToken(token);
        this.onTokenChanged?.(token);
      }
    }).catch((err: Error) => {
      // Common failure: app not registered in AGC — non-fatal
      let errObj = err as BusinessError;
      this.log.warn(TAG, `getToken failed (app not registered in AGC?): code=${errObj.code} msg=${errObj.message}`);
    });
  }

  private async loadStoredToken(): Promise<void> {
    if (!this.context) {
      return;
    }
    try {
      let prefs = await preferences.getPreferences(this.context, PREFS_NAME);
      let stored = await prefs.get(KEY_PUSH_TOKEN, '') as string;
      if (stored && stored.length > 0) {
        this.token = stored;
        this.log.info(TAG, `Loaded stored token: ${stored.substring(0, 20)}...`);
      }
    } catch (err) {
      this.log.warn(TAG, `loadStoredToken failed: ${(err as Error).message}`);
    }
  }

  private saveToken(token: string): void {
    if (!this.context) {
      return;
    }
    preferences.getPreferences(this.context, PREFS_NAME).then((prefs) => {
      return prefs.put(KEY_PUSH_TOKEN, token).then(() => prefs.flush());
    }).catch((err: Error) => {
      this.log.warn(TAG, `saveToken failed: ${err.message}`);
    });
  }
}
