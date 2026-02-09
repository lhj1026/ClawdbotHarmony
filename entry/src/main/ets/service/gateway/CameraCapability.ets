/**
 * Handles camera.snap and camera.clip commands from the gateway.
 * Uses HarmonyOS CameraKit to capture photos and record video.
 */
import { camera } from '@kit.CameraKit';
import { image } from '@kit.ImageKit';
import { media } from '@kit.MediaKit';
import { fileIo } from '@kit.CoreFileKit';
import { buffer } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { LogService } from '../../common/LogService';
import { Command } from './GatewayProtocol';

const TAG = 'CameraCap';

export class CameraCapability {
  private log: LogService = LogService.getInstance();
  private context: object | undefined = undefined;

  setContext(ctx: object): void {
    this.context = ctx;
  }

  async execute(command: string, paramsJson: string | undefined): Promise<string> {
    this.log.info(TAG, `execute: command=${command} params=${paramsJson ?? 'none'}`);

    if (command === Command.CAMERA_SNAP) {
      return await this.snap(paramsJson);
    } else if (command === Command.CAMERA_CLIP) {
      return await this.clip(paramsJson);
    }
    throw new Error(`Unsupported camera command: ${command}`);
  }

  // ---- camera.snap: Take a still photo ----

  private async snap(paramsJson: string | undefined): Promise<string> {
    let facing: string = 'back';
    let maxWidth: number = 1600;
    let quality: number = 90;

    if (paramsJson && paramsJson.length > 0) {
      try {
        let p = JSON.parse(paramsJson) as Record<string, Object>;
        if (p['facing'] !== undefined) facing = p['facing'] as string;
        if (p['maxWidth'] !== undefined) maxWidth = p['maxWidth'] as number;
        if (p['quality'] !== undefined) {
          let q: number = p['quality'] as number;
          // Accept 0-1 range or 0-100 range
          quality = q <= 1 ? Math.round(q * 100) : Math.round(q);
        }
      } catch { /* use defaults */ }
    }

    this.log.info(TAG, `snap: facing=${facing} maxWidth=${maxWidth} quality=${quality}`);

    let cameraManager: camera.CameraManager = camera.getCameraManager();
    let cameras: camera.CameraDevice[] = cameraManager.getSupportedCameras();
    this.log.info(TAG, `Available cameras: ${cameras.length}`);

    if (cameras.length === 0) {
      throw new Error('No camera available');
    }

    // Select camera by facing direction
    let targetPosition: camera.CameraPosition = facing === 'front'
      ? camera.CameraPosition.CAMERA_POSITION_FRONT
      : camera.CameraPosition.CAMERA_POSITION_BACK;

    let selectedCamera: camera.CameraDevice = cameras[0];
    for (let i = 0; i < cameras.length; i++) {
      if (cameras[i].cameraPosition === targetPosition) {
        selectedCamera = cameras[i];
        break;
      }
    }
    this.log.info(TAG, `Selected camera: id=${selectedCamera.cameraId} position=${selectedCamera.cameraPosition}`);

    // Get output capability
    let outputCap: camera.CameraOutputCapability = cameraManager.getSupportedOutputCapability(selectedCamera);
    let photoProfiles: camera.Profile[] = outputCap.photoProfiles;
    if (photoProfiles.length === 0) {
      throw new Error('No photo profile available');
    }

    // Pick the best profile (closest to maxWidth)
    let bestProfile: camera.Profile = photoProfiles[0];
    for (let i = 0; i < photoProfiles.length; i++) {
      let profile: camera.Profile = photoProfiles[i];
      if (profile.size.width <= maxWidth && profile.size.width > bestProfile.size.width) {
        bestProfile = profile;
      }
    }
    this.log.info(TAG, `Photo profile: ${bestProfile.size.width}x${bestProfile.size.height}`);

    // Create camera input
    let cameraInput: camera.CameraInput = cameraManager.createCameraInput(selectedCamera);
    await cameraInput.open();

    // Create photo output
    let photoOutput: camera.PhotoOutput = cameraManager.createPhotoOutput(bestProfile);

    // Create and configure capture session
    let session: camera.PhotoSession = cameraManager.createSession(camera.SceneMode.NORMAL_PHOTO) as camera.PhotoSession;
    session.beginConfig();
    session.addInput(cameraInput);
    session.addOutput(photoOutput);
    await session.commitConfig();
    await session.start();
    this.log.info(TAG, 'Camera session started');

    // Capture photo with Promise
    let photoResult: string = await new Promise<string>((resolve, reject) => {
      let resolved: boolean = false;

      photoOutput.on('photoAvailable', (err: BusinessError, photo: camera.Photo) => {
        if (resolved) return;
        resolved = true;

        if (err) {
          reject(new Error(`photoAvailable error: ${err.message}`));
          return;
        }

        try {
          let mainImage: image.Image = photo.main;
          mainImage.getComponent(image.ComponentType.JPEG, (compErr: BusinessError, component: image.Component) => {
            if (compErr || !component || !component.byteBuffer) {
              photo.release();
              reject(new Error('Failed to get JPEG component'));
              return;
            }

            let jpegBuffer: ArrayBuffer = component.byteBuffer;
            let base64Str: string = buffer.from(jpegBuffer).toString('base64');

            this.log.info(TAG, `Photo captured: ${jpegBuffer.byteLength} bytes, base64=${base64Str.length}`);

            photo.release();
            resolve(`{"format":"jpg","base64":${JSON.stringify(base64Str)},"width":${bestProfile.size.width},"height":${bestProfile.size.height}}`);
          });
        } catch (e) {
          photo.release();
          reject(e);
        }
      });

      // Timeout
      setTimeout(() => {
        if (!resolved) {
          resolved = true;
          reject(new Error('Photo capture timeout (10s)'));
        }
      }, 10000);

      // Trigger capture
      let captureSettings: camera.PhotoCaptureSetting = {
        quality: camera.QualityLevel.QUALITY_LEVEL_HIGH,
        rotation: camera.ImageRotation.ROTATION_0,
      };
      photoOutput.capture(captureSettings);
      this.log.info(TAG, 'Capture triggered');
    });

    // Cleanup
    await session.stop();
    session.release();
    cameraInput.close();
    photoOutput.release();
    this.log.info(TAG, 'Camera resources released');

    return photoResult;
  }

  // ---- camera.clip: Record a short video ----

  private async clip(paramsJson: string | undefined): Promise<string> {
    let facing: string = 'back';
    let durationMs: number = 3000;
    let includeAudio: boolean = true;

    if (paramsJson && paramsJson.length > 0) {
      try {
        let p = JSON.parse(paramsJson) as Record<string, Object>;
        if (p['facing'] !== undefined) facing = p['facing'] as string;
        if (p['durationMs'] !== undefined) durationMs = Math.max(1000, Math.min(60000, p['durationMs'] as number));
        if (p['includeAudio'] !== undefined) includeAudio = p['includeAudio'] as boolean;
      } catch { /* use defaults */ }
    }

    this.log.info(TAG, `clip: facing=${facing} durationMs=${durationMs} includeAudio=${includeAudio}`);

    let ctx = this.context as Record<string, string>;
    let filesDir: string = ctx['filesDir'] ?? '/data/storage/el2/base/haps/entry/files';
    let filePath: string = `${filesDir}/camera_clip_${Date.now()}.mp4`;

    let file = fileIo.openSync(filePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);

    try {
      // Create AVRecorder
      let avRecorder: media.AVRecorder = await media.createAVRecorder();

      let avProfile: media.AVRecorderProfile = {
        audioBitrate: 128000,
        audioChannels: 2,
        audioCodec: media.CodecMimeType.AUDIO_AAC,
        audioSampleRate: 48000,
        fileFormat: media.ContainerFormatType.CFT_MPEG_4,
        videoBitrate: 4000000,
        videoCodec: media.CodecMimeType.VIDEO_AVC,
        videoFrameWidth: 720,
        videoFrameHeight: 1280,
        videoFrameRate: 30,
      };

      let avConfig: media.AVRecorderConfig = {
        audioSourceType: includeAudio ? media.AudioSourceType.AUDIO_SOURCE_TYPE_MIC : media.AudioSourceType.AUDIO_SOURCE_TYPE_DEFAULT,
        videoSourceType: media.VideoSourceType.VIDEO_SOURCE_TYPE_SURFACE_ES,
        profile: avProfile,
        url: `fd://${file.fd}`,
        rotation: 0,
      };

      await avRecorder.prepare(avConfig);
      let surfaceId: string = await avRecorder.getInputSurface();
      this.log.info(TAG, `AVRecorder prepared, surfaceId=${surfaceId}`);

      // Set up camera
      let cameraManager: camera.CameraManager = camera.getCameraManager();
      let cameras: camera.CameraDevice[] = cameraManager.getSupportedCameras();
      let targetPosition: camera.CameraPosition = facing === 'front'
        ? camera.CameraPosition.CAMERA_POSITION_FRONT
        : camera.CameraPosition.CAMERA_POSITION_BACK;

      let selectedCamera: camera.CameraDevice = cameras[0];
      for (let i = 0; i < cameras.length; i++) {
        if (cameras[i].cameraPosition === targetPosition) {
          selectedCamera = cameras[i];
          break;
        }
      }

      let outputCap: camera.CameraOutputCapability = cameraManager.getSupportedOutputCapability(selectedCamera);
      let videoProfiles: camera.VideoProfile[] = outputCap.videoProfiles;
      if (videoProfiles.length === 0) {
        throw new Error('No video profile available');
      }
      let videoProfile: camera.VideoProfile = videoProfiles[0];

      let cameraInput: camera.CameraInput = cameraManager.createCameraInput(selectedCamera);
      await cameraInput.open();

      let videoOutput: camera.VideoOutput = cameraManager.createVideoOutput(videoProfile, surfaceId);

      let session: camera.VideoSession = cameraManager.createSession(camera.SceneMode.NORMAL_VIDEO) as camera.VideoSession;
      session.beginConfig();
      session.addInput(cameraInput);
      session.addOutput(videoOutput);
      await session.commitConfig();
      await session.start();
      this.log.info(TAG, 'Video session started');

      // Start recording
      await videoOutput.start();
      await avRecorder.start();
      this.log.info(TAG, `Recording video for ${durationMs}ms...`);

      // Wait for duration
      await this.delay(durationMs);

      // Stop recording
      await avRecorder.stop();
      await videoOutput.stop();
      this.log.info(TAG, 'Recording stopped');

      // Release resources
      await session.stop();
      session.release();
      cameraInput.close();
      videoOutput.release();
      await avRecorder.release();

      fileIo.closeSync(file);

      // Read file to base64
      let stat = fileIo.statSync(filePath);
      this.log.info(TAG, `Video file size: ${stat.size} bytes`);

      let readFile = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
      let buf = new ArrayBuffer(stat.size);
      fileIo.readSync(readFile.fd, buf);
      fileIo.closeSync(readFile);

      let base64Str: string = buffer.from(buf).toString('base64');

      // Clean up
      try { fileIo.unlinkSync(filePath); } catch { /* best effort */ }

      return `{"format":"mp4","base64":${JSON.stringify(base64Str)},"durationMs":${durationMs},"hasAudio":${includeAudio}}`;

    } catch (err) {
      try { fileIo.closeSync(file); } catch { /* ignore */ }
      try { fileIo.unlinkSync(filePath); } catch { /* ignore */ }
      throw err;
    }
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => { resolve(); }, ms);
    });
  }
}
