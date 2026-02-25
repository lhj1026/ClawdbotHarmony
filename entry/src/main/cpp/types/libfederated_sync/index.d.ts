/**
 * Native federated_sync module — 联邦学习同步
 *
 * C++ NAPI: 匿名化 + 模型导出/导入 + SHA256
 */

/** 初始化配置 */
interface FederatedInitConfig {
  deviceId: string;
}

/** 解析后的联邦模型结果 */
interface ParsedFederatedModel {
  communityRulesJson: string;
  linucbState: string;
  modelVersion: number;
  participantCount: number;
  communityRuleCount: number;
}

/**
 * 初始化联邦同步模块
 * @param config - 初始化配置 {deviceId}
 */
export const init: (config: FederatedInitConfig) => void;

/**
 * 设置围栏类别映射
 * @param json - JSON array: [{"geofenceId":"xxx","category":"home"},...]
 */
export const setGeofenceCategories: (json: string) => void;

/**
 * 构建联邦模型更新 (设备→服务器)
 * @param rulesJson - ContextEngine.exportRules() 输出
 * @param statsJson - ContextEngine.getStats() 输出
 * @param linucbJson - ContextEngine.exportLinUCB() 输出
 * @param patternsJson - 行为记录 JSON array
 * @param dataPoints - 本地训练样本数
 * @returns FederatedModelUpdate JSON string
 */
export const buildModelUpdate: (
  rulesJson: string,
  statsJson: string,
  linucbJson: string,
  patternsJson: string,
  dataPoints: number
) => string;

/**
 * 解析服务器返回的联邦模型，转换社区规则为引擎规则格式
 * @param modelJson - 服务器返回的 FederatedModel JSON
 * @returns 包含 communityRulesJson (引擎规则格式)、linucbState 等信息
 */
export const parseFederatedModel: (modelJson: string) => ParsedFederatedModel;

/**
 * 获取设备指纹 (SHA256 哈希)
 * @returns hex string
 */
export const getDeviceFingerprint: () => string;
