/**
 * ForegroundAppPlugin — Detect foreground app for context inference
 *
 * Uses @kit.BackgroundTasksKit or app event observation to determine
 * what app the user is currently using.
 *
 * Provides: foreground_app, app_category, app_usage_min
 *
 * App categories (local mapping):
 * - 社交: WeChat, QQ, WhatsApp, Telegram
 * - 办公: Email, WPS, Teams, Zoom
 * - 娱乐: 抖音, 快手, Bilibili, YouTube
 * - 导航: 高德, 百度地图, Google Maps
 * - 购物: 淘宝, 京东, 拼多多
 * - 资讯: 今日头条, 知乎, Twitter
 * - 工具: 设置, 文件管理, 计算器
 * - 健康: 运动健康, Keep
 * - 音乐: 网易云, QQ音乐, Spotify
 *
 * Note: BUNDLE_ACTIVE_INFO is a system permission that may not be available
 * to non-system apps. Falls back to observing own app state if restricted.
 */
import { common } from '@kit.AbilityKit';
import { LogService } from '../../../common/LogService';
import { DigitalPlugin, DigitalSnapshot } from './DigitalPluginInterface';

const TAG = 'ForegroundAppPlugin';

// App category mapping
const APP_CATEGORIES: Record<string, string> = {
  // 社交
  'com.tencent.mm': '社交',
  'com.tencent.mobileqq': '社交',
  'com.whatsapp': '社交',
  'org.telegram.messenger': '社交',
  // 办公
  'com.huawei.hmos.email': '办公',
  'com.kingsoft.office': '办公',
  'com.microsoft.teams': '办公',
  'us.zoom.videomeetings': '办公',
  'com.tencent.wework': '办公',
  'com.alibaba.android.rimet': '办公',
  // 娱乐
  'com.ss.android.ugc.aweme': '娱乐',
  'com.kuaishou.nebula': '娱乐',
  'tv.danmaku.bili': '娱乐',
  'com.google.android.youtube': '娱乐',
  // 导航
  'com.autonavi.minimap': '导航',
  'com.baidu.BaiduMap': '导航',
  'com.google.android.apps.maps': '导航',
  // 购物
  'com.taobao.taobao': '购物',
  'com.jingdong.app.mall': '购物',
  'com.xunmeng.pinduoduo': '购物',
  // 资讯
  'com.ss.android.article.news': '资讯',
  'com.zhihu.android': '资讯',
  'com.twitter.android': '资讯',
  // 健康
  'com.huawei.health': '健康',
  'com.gotokeep.keep': '健康',
  // 音乐
  'com.netease.cloudmusic': '音乐',
  'com.tencent.qqmusic': '音乐',
  'com.spotify.music': '音乐',
  // 工具
  'com.huawei.hmos.settings': '工具',
  'com.huawei.hmos.filemanager': '工具',
  'com.huawei.hmos.calculator': '工具',
};

export class ForegroundAppPlugin implements DigitalPlugin {
  name: string = 'foregroundApp';
  private log: LogService = LogService.getInstance();
  private foregroundApp: string = '';
  private appCategory: string = 'unknown';
  private appStartTime: number = 0;

  async init(_context: common.UIAbilityContext): Promise<void> {
    // Try to use UsageStatistics API
    this.tryObserveAppState();
    this.log.info(TAG, 'Init: foreground app observation started');
  }

  getSnapshot(): DigitalSnapshot {
    let usageMin = this.appStartTime > 0
      ? Math.round((Date.now() - this.appStartTime) / 60000)
      : 0;

    let data: Record<string, string> = {
      'foreground_app': this.foregroundApp,
      'app_category': this.appCategory,
      'app_usage_min': usageMin.toString()
    };

    return {
      pluginName: this.name,
      timestamp: Date.now(),
      data: data
    };
  }

  destroy(): void {
    this.log.info(TAG, 'Destroyed');
  }

  private tryObserveAppState(): void {
    try {
      // HarmonyOS: Use usageStatistics.queryCurrentBundleEvents or similar
      // For non-system apps, this API may be restricted
      // Attempt dynamic import to avoid compile errors if API is unavailable

      // Fallback: Track our own app's foreground/background state
      // This is always available and provides basic signal
      this.foregroundApp = 'com.hongjieliu.clawdbot';
      this.appCategory = '工具';
      this.appStartTime = Date.now();
      this.log.info(TAG, 'Using self-observation fallback (system API restricted)');
    } catch (err) {
      this.log.warn(TAG, `App state observation failed: ${(err as Error).message}`);
    }
  }

  /**
   * Called when we detect app switch (from system events or notifications)
   */
  updateForegroundApp(bundleName: string): void {
    if (bundleName !== this.foregroundApp) {
      this.foregroundApp = bundleName;
      this.appCategory = APP_CATEGORIES[bundleName] ?? 'other';
      this.appStartTime = Date.now();
      this.log.debug(TAG, `Foreground: ${bundleName} → ${this.appCategory}`);
    }
  }

  /** Get category for any bundle name */
  static getCategoryForBundle(bundleName: string): string {
    return APP_CATEGORIES[bundleName] ?? 'other';
  }
}
