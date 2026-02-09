/**
 * OpenClaw Gateway protocol constants.
 * Ported from Android OpenClawProtocolConstants.kt + GatewayProtocol.kt.
 */

export class GatewayProtocol {
  static readonly VERSION: number = 3;
}

export class Capability {
  static readonly Canvas: string = 'canvas';
  static readonly Camera: string = 'camera';
  static readonly Screen: string = 'screen';
  static readonly Sms: string = 'sms';
  static readonly VoiceWake: string = 'voiceWake';
  static readonly Location: string = 'location';
}

export class Command {
  // Canvas
  static readonly CANVAS_PRESENT: string = 'canvas.present';
  static readonly CANVAS_HIDE: string = 'canvas.hide';
  static readonly CANVAS_NAVIGATE: string = 'canvas.navigate';
  static readonly CANVAS_EVAL: string = 'canvas.eval';
  static readonly CANVAS_SNAPSHOT: string = 'canvas.snapshot';
  // Canvas A2UI
  static readonly CANVAS_A2UI_PUSH: string = 'canvas.a2ui.push';
  static readonly CANVAS_A2UI_PUSH_JSONL: string = 'canvas.a2ui.pushJSONL';
  static readonly CANVAS_A2UI_RESET: string = 'canvas.a2ui.reset';
  // Camera
  static readonly CAMERA_SNAP: string = 'camera.snap';
  static readonly CAMERA_CLIP: string = 'camera.clip';
  // Screen
  static readonly SCREEN_RECORD: string = 'screen.record';
  // SMS
  static readonly SMS_SEND: string = 'sms.send';
  // Location
  static readonly LOCATION_GET: string = 'location.get';
}
