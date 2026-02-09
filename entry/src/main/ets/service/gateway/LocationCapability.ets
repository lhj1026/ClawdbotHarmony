/**
 * Handles location.get commands from the gateway.
 * Ported from Android LocationCaptureManager.kt.
 */
import { geoLocationManager } from '@kit.LocationKit';
import { LogService } from '../../common/LogService';

const TAG = 'LocationCap';

export class LocationCapability {
  private log: LogService = LogService.getInstance();

  async execute(paramsJson: string | undefined): Promise<string> {
    this.log.info(TAG, `execute: params=${paramsJson ?? 'none'}`);

    let maxAgeMs: number | undefined = undefined;
    let timeoutMs: number = 10000;
    if (paramsJson && paramsJson.length > 0) {
      try {
        let p = JSON.parse(paramsJson) as Record<string, number>;
        if (p['maxAgeMs'] !== undefined) {
          maxAgeMs = p['maxAgeMs'];
        }
        if (p['timeoutMs'] !== undefined) {
          timeoutMs = Math.max(1000, Math.min(60000, p['timeoutMs']));
        }
      } catch {
        this.log.warn(TAG, 'Failed to parse params, using defaults');
      }
    }

    this.log.debug(TAG, `maxAgeMs=${maxAgeMs ?? 'none'} timeoutMs=${timeoutMs}`);

    // Try cached location first
    if (maxAgeMs !== undefined) {
      try {
        let cached = geoLocationManager.getLastLocation();
        if (cached) {
          let age = Date.now() - cached.timeStamp;
          this.log.debug(TAG, `Cached location age=${age}ms maxAge=${maxAgeMs}ms`);
          if (age <= maxAgeMs) {
            this.log.info(TAG, `Using cached location: lat=${cached.latitude} lon=${cached.longitude} accuracy=${cached.accuracy}m`);
            return this.formatLocation(cached);
          }
        }
      } catch {
        this.log.debug(TAG, 'No cached location available');
      }
    }

    // Request fresh location
    this.log.info(TAG, `Requesting fresh location (timeout=${timeoutMs}ms)...`);
    let request: geoLocationManager.SingleLocationRequest = {
      locatingPriority: geoLocationManager.LocatingPriority.PRIORITY_LOCATING_SPEED,
      locatingTimeoutMs: timeoutMs,
    };

    let location = await geoLocationManager.getCurrentLocation(request);
    this.log.info(TAG, `Fresh location: lat=${location.latitude} lon=${location.longitude} accuracy=${location.accuracy}m`);
    return this.formatLocation(location);
  }

  private formatLocation(loc: geoLocationManager.Location): string {
    let parts: string = `"lat":${loc.latitude},"lon":${loc.longitude},"accuracyMeters":${loc.accuracy},"timestamp":${JSON.stringify(new Date(loc.timeStamp).toISOString())},"isPrecise":${loc.accuracy < 50},"source":"gps"`;
    if (loc.altitude !== undefined && loc.altitude !== 0) {
      parts += `,"altitudeMeters":${loc.altitude}`;
    }
    if (loc.speed !== undefined && loc.speed > 0) {
      parts += `,"speedMps":${loc.speed}`;
    }
    if (loc.direction !== undefined && loc.direction > 0) {
      parts += `,"headingDeg":${loc.direction}`;
    }
    return `{${parts}}`;
  }
}
