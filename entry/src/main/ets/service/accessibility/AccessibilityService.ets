/**
 * AccessibilityService — 无障碍服务单例
 *
 * 通过 AccessibilityExtensionAbility 的 context 读取和操控其他应用界面。
 * 由 ClawdBotAccessibilityExtension.onConnect() 初始化，供 NodeRuntime 调用。
 */
import { AccessibilityExtensionContext, AccessibilityElement, Rect } from '@ohos.application.AccessibilityExtensionAbility';
import { LogService } from '../../common/LogService';

const TAG = 'A11yService';

// ==================== 类型定义 ====================

export interface ElementBounds {
  left: number;
  top: number;
  width: number;
  height: number;
}

export interface ScreenNode {
  id: number;
  text: string;
  type: string;
  bounds: ElementBounds;
  children: ScreenNode[];
}

export interface WindowInfo {
  id: number;
  type: string;
  isActive: boolean;
  isFocused: boolean;
  bounds: ElementBounds;
}

// ==================== 实现 ====================

export class AccessibilityService {
  private static instance: AccessibilityService | undefined = undefined;
  private log: LogService = LogService.getInstance();

  private ctx: AccessibilityExtensionContext | undefined = undefined;
  // 元素缓存：通过 nodeId 快速查找 AccessibilityElement
  private elementCache: Map<number, AccessibilityElement> = new Map();
  // 保留 key 列表，供无解构的遍历使用（ArkTS 不支持 for-of Map 解构）
  private elementCacheKeys: number[] = [];
  private nodeIdCounter: number = 0;

  private constructor() {}

  static getInstance(): AccessibilityService {
    if (!AccessibilityService.instance) {
      AccessibilityService.instance = new AccessibilityService();
    }
    return AccessibilityService.instance;
  }

  init(context: AccessibilityExtensionContext): void {
    this.ctx = context;
    this.clearCache();
    this.log.info(TAG, 'AccessibilityService initialized');
  }

  destroy(): void {
    this.ctx = undefined;
    this.clearCache();
    this.log.info(TAG, 'AccessibilityService destroyed');
  }

  isReady(): boolean {
    return this.ctx !== undefined;
  }

  // ==================== 屏幕内容 ====================

  /**
   * 获取当前屏幕 UI 树（简化版）。
   * 递归读取各窗口根元素，返回 ScreenNode 数组（每个窗口一棵树）。
   */
  async getScreenContent(): Promise<ScreenNode[]> {
    if (!this.ctx) {
      this.log.warn(TAG, 'getScreenContent: context not ready');
      return [];
    }

    this.clearCache();

    try {
      let windows = await this.ctx.getWindows();
      let result: ScreenNode[] = [];

      for (let i = 0; i < windows.length; i++) {
        let winElem = windows[i];
        try {
          let winId: number = await winElem.attributeValue('windowId');
          let root: AccessibilityElement = await this.ctx.getWindowRootElement(winId);
          let node = await this.buildNode(root, 0);
          result.push(node);
        } catch (err) {
          this.log.warn(TAG, `getScreenContent: window error: ${(err as Error).message ?? String(err)}`);
        }
      }

      this.log.info(TAG, `getScreenContent: ${result.length} windows, ${this.elementCache.size} elements cached`);
      return result;
    } catch (err) {
      this.log.error(TAG, `getScreenContent error: ${(err as Error).message ?? String(err)}`);
      return [];
    }
  }

  /**
   * 按文本内容查找元素（在最近一次 getScreenContent 缓存的元素中搜索）。
   * 若缓存为空则先刷新。
   */
  async findElements(text: string): Promise<ScreenNode[]> {
    if (!this.ctx) {
      this.log.warn(TAG, 'findElements: context not ready');
      return [];
    }

    if (this.elementCache.size === 0) {
      await this.getScreenContent();
    }

    let lower = text.toLowerCase();
    let matches: ScreenNode[] = [];

    for (let i = 0; i < this.elementCacheKeys.length; i++) {
      let nodeId = this.elementCacheKeys[i];
      let elem = this.elementCache.get(nodeId);
      if (elem === undefined) {
        continue;
      }
      try {
        let elemText: string = await elem.attributeValue('text');
        if (elemText && elemText.toLowerCase().includes(lower)) {
          let node = await this.buildNodeShallow(nodeId, elem);
          matches.push(node);
        }
      } catch {
        // ignore individual failures
      }
    }

    this.log.info(TAG, `findElements("${text}"): ${matches.length} matches`);
    return matches;
  }

  /**
   * 点击指定节点（通过缓存的 element 引用）。
   */
  async performClick(nodeId: number): Promise<boolean> {
    let elem = this.elementCache.get(nodeId);
    if (!elem) {
      this.log.warn(TAG, `performClick: nodeId=${nodeId} not found in cache`);
      return false;
    }
    try {
      await elem.performAction('click');
      this.log.info(TAG, `performClick: nodeId=${nodeId} clicked`);
      return true;
    } catch (err) {
      this.log.error(TAG, `performClick: nodeId=${nodeId} error: ${(err as Error).message ?? String(err)}`);
      return false;
    }
  }

  /**
   * 滚动（up/down/left/right）。
   */
  async performScroll(direction: string): Promise<boolean> {
    if (!this.ctx) {
      this.log.warn(TAG, 'performScroll: context not ready');
      return false;
    }
    let actionName = (direction === 'up' || direction === 'left') ? 'scrollBackward' : 'scrollForward';

    // 先尝试焦点元素
    try {
      let focusElem: AccessibilityElement = await this.ctx.getFocusElement(false);
      await focusElem.performAction(actionName);
      this.log.info(TAG, `performScroll: ${direction} on focus element`);
      return true;
    } catch {
      // 无焦点元素，继续降级
    }

    // 降级：对当前窗口根元素执行滚动
    try {
      let root: AccessibilityElement = await this.ctx.getWindowRootElement();
      await root.performAction(actionName);
      this.log.info(TAG, `performScroll: ${direction} on root element`);
      return true;
    } catch (err) {
      this.log.warn(TAG, `performScroll: root element failed: ${(err as Error).message ?? String(err)}`);
    }

    this.log.warn(TAG, `performScroll: no scrollable element found`);
    return false;
  }

  /**
   * 获取窗口列表。
   */
  async getWindowInfo(): Promise<WindowInfo[]> {
    if (!this.ctx) {
      this.log.warn(TAG, 'getWindowInfo: context not ready');
      return [];
    }
    try {
      let windows = await this.ctx.getWindows();
      let result: WindowInfo[] = [];

      for (let i = 0; i < windows.length; i++) {
        let winElem = windows[i];
        let winId: number = 0;
        let isActive: boolean = false;
        let isFocused: boolean = false;
        let bounds: ElementBounds = { left: 0, top: 0, width: 0, height: 0 };

        try { winId = await winElem.attributeValue('windowId'); } catch { /* ignore */ }
        try { isActive = await winElem.attributeValue('isActive'); } catch { /* ignore */ }
        try { isFocused = await winElem.attributeValue('isFocused'); } catch { /* ignore */ }
        try {
          let rect = await winElem.attributeValue('screenRect');
          bounds = { left: rect.left, top: rect.top, width: rect.width, height: rect.height };
        } catch { /* ignore */ }

        let info: WindowInfo = {
          id: winId,
          type: 'normal',
          isActive: isActive,
          isFocused: isFocused,
          bounds: bounds,
        };
        result.push(info);
      }

      this.log.info(TAG, `getWindowInfo: ${result.length} windows`);
      return result;
    } catch (err) {
      this.log.error(TAG, `getWindowInfo error: ${(err as Error).message ?? String(err)}`);
      return [];
    }
  }

  /**
   * 向当前焦点输入框注入文本。
   */
  async injectText(text: string): Promise<boolean> {
    if (!this.ctx) {
      this.log.warn(TAG, 'injectText: context not ready');
      return false;
    }
    try {
      let focusElem: AccessibilityElement = await this.ctx.getFocusElement(false);
      await focusElem.performAction('setText', { 'text': text });
      this.log.info(TAG, `injectText: "${text.substring(0, 30)}" injected via focus`);
      return true;
    } catch {
      // 无焦点元素，降级搜索
    }

    // 降级：查找缓存中 componentType 包含 'text' 的元素（输入框）
    for (let i = 0; i < this.elementCacheKeys.length; i++) {
      let nodeId = this.elementCacheKeys[i];
      let elem = this.elementCache.get(nodeId);
      if (elem === undefined) {
        continue;
      }
      try {
        let compType: string = await elem.attributeValue('componentType');
        if (compType && compType.toLowerCase().includes('text')) {
          await elem.performAction('setText', { 'text': text });
          this.log.info(TAG, `injectText: "${text.substring(0, 30)}" → nodeId=${nodeId}`);
          return true;
        }
      } catch {
        // try next
      }
    }

    this.log.warn(TAG, 'injectText: no editable element found');
    return false;
  }

  // ==================== 私有辅助 ====================

  private clearCache(): void {
    this.elementCache.clear();
    this.elementCacheKeys = [];
    this.nodeIdCounter = 0;
  }

  private cacheElement(elem: AccessibilityElement): number {
    let nodeId = ++this.nodeIdCounter;
    this.elementCache.set(nodeId, elem);
    this.elementCacheKeys.push(nodeId);
    return nodeId;
  }

  private async buildNode(elem: AccessibilityElement, depth: number): Promise<ScreenNode> {
    let nodeId = this.cacheElement(elem);
    let text = '';
    let type = '';
    let bounds: ElementBounds = { left: 0, top: 0, width: 0, height: 0 };

    try { text = await elem.attributeValue('text'); } catch { /* ignore */ }
    try { type = await elem.attributeValue('componentType'); } catch { /* ignore */ }
    try {
      let rect = await elem.attributeValue('screenRect');
      bounds = { left: rect.left, top: rect.top, width: rect.width, height: rect.height };
    } catch { /* ignore */ }

    let children: ScreenNode[] = [];
    // 限制深度为8层，避免深层遍历耗时过长
    if (depth < 8) {
      try {
        let childElems: AccessibilityElement[] = await elem.attributeValue('children');
        if (childElems && childElems.length > 0) {
          let maxChildren = Math.min(childElems.length, 30);
          for (let i = 0; i < maxChildren; i++) {
            let child = await this.buildNode(childElems[i], depth + 1);
            children.push(child);
          }
        }
      } catch { /* ignore */ }
    }

    let node: ScreenNode = { id: nodeId, text: text, type: type, bounds: bounds, children: children };
    return node;
  }

  private async buildNodeShallow(nodeId: number, elem: AccessibilityElement): Promise<ScreenNode> {
    let text = '';
    let type = '';
    let bounds: ElementBounds = { left: 0, top: 0, width: 0, height: 0 };

    try { text = await elem.attributeValue('text'); } catch { /* ignore */ }
    try { type = await elem.attributeValue('componentType'); } catch { /* ignore */ }
    try {
      let rect = await elem.attributeValue('screenRect');
      bounds = { left: rect.left, top: rect.top, width: rect.width, height: rect.height };
    } catch { /* ignore */ }

    let node: ScreenNode = { id: nodeId, text: text, type: type, bounds: bounds, children: [] };
    return node;
  }
}
