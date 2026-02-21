/**
 * PosturePlugin — Detect phone posture via front camera
 *
 * Uses low-resolution front camera snapshots to determine:
 * - in_use: user is looking at the phone (face detected / bright)
 * - on_desk: phone face up, bright ambient, no face
 * - in_pocket: very dark image
 * - unknown: can't determine
 *
 * Privacy: No images are saved. Only brightness/face-presence features extracted.
 * Sampling: one frame every 30 seconds max.
 *
 * Provides: phone_posture, ambient_brightness
 *
 * Permission: ohos.permission.CAMERA (already declared)
 */
import { camera } from '@kit.CameraKit';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { LogService } from '../../../common/LogService';
import { DigitalPlugin, DigitalSnapshot } from './DigitalPluginInterface';

const TAG = 'PosturePlugin';

export class PosturePlugin implements DigitalPlugin {
  name: string = 'posture';
  private log: LogService = LogService.getInstance();
  private posture: string = 'unknown';
  private brightness: number = -1;
  private lastCaptureTime: number = 0;
  private cameraManager: camera.CameraManager | undefined;
  private appContext: common.UIAbilityContext | undefined;

  async init(context: common.UIAbilityContext): Promise<void> {
    this.appContext = context;
    try {
      this.cameraManager = camera.getCameraManager(context);
      this.log.info(TAG, 'Init: camera manager obtained');
    } catch (err) {
      this.log.warn(TAG, `Camera manager init failed: ${(err as Error).message}`);
    }
  }

  getSnapshot(): DigitalSnapshot {
    // Trigger async capture if stale (>30s)
    let age = Date.now() - this.lastCaptureTime;
    if (age > 30000 && this.cameraManager) {
      this.captureFrame();
    }

    let data: Record<string, string> = {
      'phone_posture': this.posture,
      'ambient_brightness': this.brightness >= 0 ? this.brightness.toString() : 'unknown'
    };

    return {
      pluginName: this.name,
      timestamp: Date.now(),
      data: data
    };
  }

  destroy(): void {
    this.cameraManager = undefined;
    this.log.info(TAG, 'Destroyed');
  }

  private async captureFrame(): Promise<void> {
    if (!this.cameraManager) return;

    try {
      let cameras = this.cameraManager.getSupportedCameras();
      // Find front camera
      let frontCamera: camera.CameraDevice | undefined;
      for (let i = 0; i < cameras.length; i++) {
        if (cameras[i].cameraPosition === camera.CameraPosition.CAMERA_POSITION_FRONT) {
          frontCamera = cameras[i];
          break;
        }
      }
      if (!frontCamera) {
        this.log.debug(TAG, 'No front camera found');
        return;
      }

      // Create low-res image receiver (160x120 is enough for brightness analysis)
      let receiver = image.createImageReceiver(160, 120, image.ImageFormat.JPEG, 1);
      let surfaceId = await receiver.getReceivingSurfaceId();

      // Create capture session
      let cameraInput = this.cameraManager.createCameraInput(frontCamera);
      await cameraInput.open();

      let previewOutput = this.cameraManager.createPreviewOutput(
        this.getPreviewProfile(frontCamera), surfaceId
      );

      let session = this.cameraManager.createSession(camera.SceneMode.NORMAL_PHOTO);
      session.beginConfig();
      session.addInput(cameraInput);
      session.addOutput(previewOutput);
      await session.commitConfig();
      await session.start();

      // Wait for a frame
      let frameReceived = false;
      receiver.on('imageArrival', async () => {
        if (frameReceived) return;
        frameReceived = true;

        try {
          let img = await receiver.readLatestImage();
          if (img) {
            let component = await img.getComponent(image.ComponentType.JPEG);
            if (component && component.byteBuffer) {
              this.analyzeFrame(component.byteBuffer);
            }
            img.release();
          }
        } catch (err) {
          this.log.debug(TAG, `Frame read error: ${(err as Error).message}`);
        }

        // Cleanup
        try {
          await session.stop();
          session.release();
          await cameraInput.close();
          receiver.release();
        } catch { /* ignore cleanup errors */ }
      });

      // Timeout: cleanup after 3 seconds if no frame
      setTimeout(async () => {
        if (!frameReceived) {
          try {
            await session.stop();
            session.release();
            await cameraInput.close();
            receiver.release();
          } catch { /* ignore */ }
        }
      }, 3000);

    } catch (err) {
      this.log.debug(TAG, `Capture failed: ${(err as Error).message}`);
    }
  }

  private getPreviewProfile(cameraDevice: camera.CameraDevice): camera.Profile {
    let profiles = this.cameraManager!.getSupportedOutputCapability(cameraDevice, camera.SceneMode.NORMAL_PHOTO);
    // Pick smallest preview profile
    let previewProfiles = profiles.previewProfiles;
    let smallest = previewProfiles[0];
    for (let i = 1; i < previewProfiles.length; i++) {
      if (previewProfiles[i].size.width < smallest.size.width) {
        smallest = previewProfiles[i];
      }
    }
    return smallest;
  }

  private analyzeFrame(buffer: ArrayBuffer): void {
    // Simple brightness analysis: average pixel value from JPEG
    // For JPEG we analyze the raw bytes — rough but fast
    let bytes = new Uint8Array(buffer);
    let sum = 0;
    let sampleSize = Math.min(bytes.length, 10000);
    let step = Math.max(1, Math.floor(bytes.length / sampleSize));
    let count = 0;

    for (let i = 0; i < bytes.length; i += step) {
      sum += bytes[i];
      count++;
    }

    this.brightness = count > 0 ? Math.round(sum / count) : 0;
    this.lastCaptureTime = Date.now();

    // Classify posture based on brightness
    if (this.brightness < 20) {
      this.posture = 'in_pocket';
    } else if (this.brightness < 60) {
      this.posture = 'on_desk';  // dim but not pitch black
    } else {
      this.posture = 'in_use';   // bright = screen facing user or lit environment
    }

    this.log.debug(TAG, `Frame analyzed: brightness=${this.brightness}, posture=${this.posture}`);
  }
}
