/**
 * Stores and retrieves gateway auth tokens per (deviceId, role).
 * Ported from Android DeviceAuthStore.kt.
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Constants } from '../../common/Constants';
import { LogService } from '../../common/LogService';

const TAG = 'DeviceAuth';

export class DeviceAuthStore {
  private log: LogService = LogService.getInstance();

  async loadToken(context: common.UIAbilityContext, deviceId: string, role: string): Promise<string | undefined> {
    try {
      let store = await preferences.getPreferences(context, Constants.PREFS_DEVICE_AUTH);
      let key = this.tokenKey(deviceId, role);
      let val = (await store.get(key, '')) as string;
      if (val.length > 0) {
        this.log.debug(TAG, `loadToken: found token for role=${role} deviceId=${deviceId.substring(0, 12)}... (${val.length} chars)`);
        return val;
      }
      this.log.debug(TAG, `loadToken: no token for role=${role} deviceId=${deviceId.substring(0, 12)}...`);
      return undefined;
    } catch (err) {
      let msg = (err as Error).message ?? 'unknown';
      this.log.error(TAG, `loadToken failed: ${msg}`);
      return undefined;
    }
  }

  async saveToken(context: common.UIAbilityContext, deviceId: string, role: string, token: string): Promise<void> {
    try {
      this.log.info(TAG, `saveToken: role=${role} deviceId=${deviceId.substring(0, 12)}... token=${token.substring(0, 8)}... (${token.length} chars)`);
      let store = await preferences.getPreferences(context, Constants.PREFS_DEVICE_AUTH);
      await store.put(this.tokenKey(deviceId, role), token.trim());
      await store.flush();
      this.log.info(TAG, 'saveToken: saved successfully');
    } catch (err) {
      let msg = (err as Error).message ?? 'unknown';
      this.log.error(TAG, `saveToken failed: ${msg}`);
    }
  }

  async clearToken(context: common.UIAbilityContext, deviceId: string, role: string): Promise<void> {
    try {
      this.log.info(TAG, `clearToken: role=${role} deviceId=${deviceId.substring(0, 12)}...`);
      let store = await preferences.getPreferences(context, Constants.PREFS_DEVICE_AUTH);
      await store.delete(this.tokenKey(deviceId, role));
      await store.flush();
      this.log.info(TAG, 'clearToken: cleared successfully');
    } catch (err) {
      let msg = (err as Error).message ?? 'unknown';
      this.log.error(TAG, `clearToken failed: ${msg}`);
    }
  }

  private tokenKey(deviceId: string, role: string): string {
    return `token_${deviceId.trim().toLowerCase()}_${role.trim().toLowerCase()}`;
  }
}
