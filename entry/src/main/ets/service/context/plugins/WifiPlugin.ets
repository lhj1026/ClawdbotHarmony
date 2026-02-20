/**
 * WifiPlugin — Detect WiFi connection state and network info
 *
 * Uses @kit.ConnectivityKit (wifiManager) to check current WiFi connection
 * status, SSID, signal strength (RSSI), and frequency band.
 *
 * Provides: wifi_connected, wifi_ssid, wifi_rssi, wifi_frequency
 *
 * Permission: ohos.permission.GET_NETWORK_INFO (already declared)
 * API: @kit.ConnectivityKit — wifiManager
 */
import { wifiManager } from '@kit.ConnectivityKit';
import { common } from '@kit.AbilityKit';
import { LogService } from '../../../common/LogService';
import { DigitalPlugin, DigitalSnapshot } from './DigitalPluginInterface';

const TAG = 'WifiPlugin';

export class WifiPlugin implements DigitalPlugin {
  name: string = 'wifi';
  private log: LogService = LogService.getInstance();
  private connected: boolean = false;
  private ssid: string = '';
  private rssi: number = 0;
  private frequency: number = 0;
  private connectionChangeRegistered: boolean = false;

  async init(_context: common.UIAbilityContext): Promise<void> {
    this.refreshState();
    this.registerConnectionListener();
    this.log.info(TAG, `Init: connected=${this.connected}, ssid=${this.ssid}`);
  }

  getSnapshot(): DigitalSnapshot {
    this.refreshState();

    let band = 'unknown';
    if (this.frequency > 0 && this.frequency < 3000) {
      band = '2.4GHz';
    } else if (this.frequency >= 5000) {
      band = '5GHz';
    }

    let data: Record<string, string> = {
      'wifi_connected': this.connected ? 'true' : 'false',
      'wifi_ssid': this.connected ? this.ssid : '',
      'wifi_rssi': this.connected ? this.rssi.toString() : '0',
      'wifi_frequency': this.connected ? band : ''
    };

    return {
      pluginName: this.name,
      timestamp: Date.now(),
      data: data
    };
  }

  destroy(): void {
    this.unregisterConnectionListener();
    this.log.info(TAG, 'Destroyed');
  }

  private refreshState(): void {
    try {
      this.connected = wifiManager.isConnected();
    } catch {
      this.connected = false;
    }

    if (!this.connected) {
      this.ssid = '';
      this.rssi = 0;
      this.frequency = 0;
      return;
    }

    try {
      let info = wifiManager.getLinkedInfo();
      this.ssid = info.ssid || '';
      this.rssi = info.rssi || 0;
      this.frequency = info.frequency || 0;
    } catch {
      this.ssid = '';
      this.rssi = 0;
      this.frequency = 0;
    }
  }

  private registerConnectionListener(): void {
    try {
      wifiManager.on('wifiConnectionChange', (state: number) => {
        this.connected = (state === 1);
        if (this.connected) {
          this.refreshState();
        } else {
          this.ssid = '';
          this.rssi = 0;
          this.frequency = 0;
        }
      });
      this.connectionChangeRegistered = true;
    } catch (err) {
      this.log.warn(TAG, `Failed to register WiFi listener: ${(err as Error).message}`);
    }
  }

  private unregisterConnectionListener(): void {
    if (!this.connectionChangeRegistered) return;
    try {
      wifiManager.off('wifiConnectionChange');
      this.connectionChangeRegistered = false;
    } catch {
      // ignore
    }
  }
}
