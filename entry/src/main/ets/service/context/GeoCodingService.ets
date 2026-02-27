/**
 * GeoCodingService - 地理编码服务
 *
 * 使用 OpenStreetMap Nominatim API 进行逆地理编码
 * 将经纬度转换为可读的地点名称
 */
import { http } from '@kit.NetworkKit';
import { LogService } from '../../common/LogService';

const TAG = 'GeoCodingService';

/** 逆地理编码结果 */
export interface ReverseGeocodingResult {
  success: boolean;
  displayName?: string;       // 完整地址
  name?: string;              // 简短名称（如店名）
  category?: string;          // 类别（amenity, shop, office 等）
  type?: string;              // 类型（cafe, restaurant, fuel 等）
  address?: GeocodedAddress;
  error?: string;
}

/** 正地理编码结果 (地名 → 经纬度) */
export interface ForwardGeocodingResult {
  success: boolean;
  latitude?: number;
  longitude?: number;
  displayName?: string;
  category?: string;
  error?: string;
}

/** 地址详情 */
export interface GeocodedAddress {
  houseNumber?: string;
  road?: string;
  neighbourhood?: string;
  suburb?: string;
  city?: string;
  county?: string;
  state?: string;
  postcode?: string;
  country?: string;
}

/** 缓存条目 */
interface CacheEntry {
  result: ReverseGeocodingResult;
  timestamp: number;
}

/** 地点类型到分类的映射 */
const TYPE_TO_CATEGORY: Record<string, string> = {
  'cafe': 'restaurant',
  'restaurant': 'restaurant',
  'fast_food': 'restaurant',
  'pub': 'restaurant',
  'bar': 'restaurant',
  'food_court': 'restaurant',
  'supermarket': 'shopping',
  'convenience': 'shopping',
  'mall': 'shopping',
  'department_store': 'shopping',
  'clothes': 'shopping',
  'fuel': 'transit',
  'parking': 'transit',
  'bus_station': 'transit',
  'train_station': 'transit',
  'subway_station': 'transit',
  'airport': 'transit',
  'office': 'work',
  'bank': 'work',
  'gym': 'gym',
  'fitness_centre': 'gym',
  'sports_centre': 'gym',
  'hospital': 'custom',
  'pharmacy': 'custom',
  'school': 'custom',
  'university': 'custom',
  'library': 'custom',
  'park': 'custom',
  'residential': 'home',
  'apartments': 'home',
  'house': 'home',
};

export class GeoCodingService {
  private static instance: GeoCodingService;
  private log: LogService = LogService.getInstance();

  private cache: Map<string, CacheEntry> = new Map();
  private cacheExpiryMs: number = 86400000; // 24小时
  private lastRequestTime: number = 0;
  private minRequestIntervalMs: number = 1100; // Nominatim 要求每秒最多1次

  private constructor() {}

  static getInstance(): GeoCodingService {
    if (!GeoCodingService.instance) {
      GeoCodingService.instance = new GeoCodingService();
    }
    return GeoCodingService.instance;
  }

  /**
   * 逆地理编码 - 将经纬度转换为地点名称
   * @param lat 纬度
   * @param lon 经度
   * @returns 地理编码结果
   */
  async reverseGeocode(lat: number, lon: number): Promise<ReverseGeocodingResult> {
    let cacheKey = `${lat.toFixed(4)},${lon.toFixed(4)}`;

    let cached = this.cache.get(cacheKey);
    if (cached && Date.now() - cached.timestamp < this.cacheExpiryMs) {
      this.log.debug(TAG, `Cache hit for ${cacheKey}`);
      return cached.result;
    }

    await this.rateLimit();

    try {
      let url = `https://nominatim.openstreetmap.org/reverse?format=json&lat=${lat}&lon=${lon}&zoom=18&addressdetails=1`;

      let request = http.createHttp();

      let response = await request.request(url, {
        method: http.RequestMethod.GET,
        header: { 'User-Agent': 'ClawdBotHarmony/1.0', 'Accept-Language': 'zh-CN,zh,en' },
        connectTimeout: 10000,
        readTimeout: 10000,
      });

      request.destroy();

      if (response.responseCode !== 200) {
        let result: ReverseGeocodingResult = {
          success: false,
          error: `HTTP ${response.responseCode}`,
        };
        this.cache.set(cacheKey, { result, timestamp: Date.now() });
        return result;
      }

      let body = response.result as string;
      let data = JSON.parse(body) as Record<string, Object>;

      if (data['error']) {
        let result: ReverseGeocodingResult = {
          success: false,
          error: String(data['error']),
        };
        this.cache.set(cacheKey, { result, timestamp: Date.now() });
        return result;
      }

      let address = this.parseAddress(data['address'] as Record<string, string>);
      let name = this.extractName(data, address);
      let type = String(data['type'] || '');
      let category = this.inferCategory(type, data);

      let result: ReverseGeocodingResult = {
        success: true,
        displayName: String(data['display_name'] || ''),
        name: name,
        category: category,
        type: type,
        address: address,
      };

      this.cache.set(cacheKey, { result, timestamp: Date.now() });
      this.log.info(TAG, `Geocoded: ${name} (${category})`);
      return result;

    } catch (err) {
      this.log.warn(TAG, `Geocoding error: ${(err as Error).message}`);
      let result: ReverseGeocodingResult = {
        success: false,
        error: (err as Error).message,
      };
      return result;
    }
  }

  /**
   * 正地理编码 - 将地名转换为经纬度
   * @param query 地名（如 "首都机场", "北京大学"）
   * @returns 地理编码结果
   */
  async forwardGeocode(query: string): Promise<ForwardGeocodingResult> {
    if (!query || query.trim().length === 0) {
      return { success: false, error: 'Empty query' };
    }

    await this.rateLimit();

    try {
      let encoded = encodeURIComponent(query.trim());
      let url = `https://nominatim.openstreetmap.org/search?format=json&q=${encoded}&limit=1&addressdetails=1`;

      let request = http.createHttp();

      let response = await request.request(url, {
        method: http.RequestMethod.GET,
        header: { 'User-Agent': 'ClawdBotHarmony/1.0', 'Accept-Language': 'zh-CN,zh,en' },
        connectTimeout: 10000,
        readTimeout: 10000,
      });

      request.destroy();

      if (response.responseCode !== 200) {
        return { success: false, error: `HTTP ${response.responseCode}` };
      }

      let body = response.result as string;
      let results = JSON.parse(body) as Record<string, Object>[];

      if (!results || results.length === 0) {
        return { success: false, error: 'No results found' };
      }

      let first = results[0];
      let lat = parseFloat(String(first['lat']));
      let lon = parseFloat(String(first['lon']));
      let type = String(first['type'] || '');
      let category = this.inferCategory(type, first);

      this.log.info(TAG, `Forward geocoded "${query}" → (${lat}, ${lon}) type=${type}`);

      return {
        success: true,
        latitude: lat,
        longitude: lon,
        displayName: String(first['display_name'] || query),
        category: category,
      };

    } catch (err) {
      this.log.warn(TAG, `Forward geocoding error: ${(err as Error).message}`);
      return { success: false, error: (err as Error).message };
    }
  }

  /**
   * 解析地址对象
   */
  private parseAddress(addr: Record<string, string> | undefined): GeocodedAddress {
    if (!addr) return {};
    return {
      houseNumber: addr['house_number'],
      road: addr['road'],
      neighbourhood: addr['neighbourhood'],
      suburb: addr['suburb'],
      city: addr['city'] || addr['town'] || addr['village'],
      county: addr['county'],
      state: addr['state'],
      postcode: addr['postcode'],
      country: addr['country'],
    };
  }

  /**
   * 提取简短名称
   */
  private extractName(data: Record<string, Object>, address: GeocodedAddress): string {
    let name = data['name'] as string;
    if (name) return name;

    let namedDetails = [
      data['amenity'] as string,
      data['shop'] as string,
      data['office'] as string,
      data['building'] as string,
      data['leisure'] as string,
    ].filter(n => n && n.length > 0);

    if (namedDetails.length > 0) {
      return namedDetails[0];
    }

    let parts: string[] = [];
    if (address.road) parts.push(address.road);
    if (address.neighbourhood) parts.push(address.neighbourhood);
    if (address.suburb) parts.push(address.suburb);
    if (parts.length > 0) {
      return parts.join(', ');
    }

    return 'Unknown Location';
  }

  /**
   * 推断地点类别
   */
  private inferCategory(type: string, data: Record<string, Object>): string {
    if (TYPE_TO_CATEGORY[type]) {
      return TYPE_TO_CATEGORY[type];
    }

    let amenity = data['amenity'] as string;
    if (amenity && TYPE_TO_CATEGORY[amenity]) {
      return TYPE_TO_CATEGORY[amenity];
    }

    let shop = data['shop'] as string;
    if (shop && TYPE_TO_CATEGORY[shop]) {
      return TYPE_TO_CATEGORY[shop];
    }

    return 'custom';
  }

  /**
   * 速率限制
   */
  private async rateLimit(): Promise<void> {
    let elapsed = Date.now() - this.lastRequestTime;
    if (elapsed < this.minRequestIntervalMs) {
      await new Promise<void>(resolve => {
        setTimeout(() => resolve(), this.minRequestIntervalMs - elapsed);
      });
    }
    this.lastRequestTime = Date.now();
  }

  /**
   * 清除缓存
   */
  clearCache(): void {
    this.cache.clear();
    this.log.info(TAG, 'Cache cleared');
  }

  /**
   * 获取缓存大小
   */
  getCacheSize(): number {
    return this.cache.size;
  }
}
