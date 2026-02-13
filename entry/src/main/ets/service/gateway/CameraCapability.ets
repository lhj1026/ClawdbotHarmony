/**
 * Handles camera.snap and camera.clip commands from the gateway.
 * Uses Camera Kit API for auto-capture (no user interaction required).
 */
import { camera } from '@kit.CameraKit';
import { cameraPicker } from '@kit.CameraKit';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { buffer } from '@kit.ArkTS';
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { LogService } from '../../common/LogService';
import { Command } from './GatewayProtocol';

const TAG = 'CameraCap';

export class CameraCapability {
  private log: LogService = LogService.getInstance();
  private appContext: Context | undefined = undefined;

  setContext(ctx: Context): void {
    this.appContext = ctx;
  }

  async execute(command: string, paramsJson: string | undefined): Promise<string> {
    this.log.info(TAG, `execute: command=${command} params=${paramsJson ?? 'none'}`);

    try {
      if (command === Command.CAMERA_SNAP) {
        return await this.snap(paramsJson);
      } else if (command === Command.CAMERA_CLIP) {
        return await this.clip(paramsJson);
      }
    } catch (err) {
      let msg = (err as Error).message ?? 'unknown error';
      this.log.error(TAG, `execute FAILED: ${command} - ${msg}`);
      throw err as Error;
    }
    throw new Error(`Unsupported camera command: ${command}`);
  }

  // ---- camera.snap (auto-capture, no UI) ----

  private async snap(paramsJson: string | undefined): Promise<string> {
    if (!this.appContext) {
      throw new Error('Context not set');
    }

    let facing: string = 'back';
    if (paramsJson && paramsJson.length > 0) {
      try {
        let p = JSON.parse(paramsJson) as Record<string, Object>;
        if (p['facing'] !== undefined) facing = p['facing'] as string;
      } catch { /* defaults */ }
    }

    let timestamp = Date.now();
    let savePath = await this.autoCapture(facing, `${this.appContext.cacheDir}/snap_${timestamp}.jpg`);

    // Compress image to avoid WebSocket frame size limit (code 1009)
    let readResult = await this.compressAndEncode('', savePath);
    this.log.info(TAG, `Photo: ${readResult.size} bytes (base64: ${readResult.base64.length})`);

    // Save compressed photo to persistent storage for display in chat
    let photosDir = `${this.appContext!.filesDir}/photos`;
    try { fileIo.mkdirSync(photosDir); } catch { /* already exists */ }
    let persistPath = `${photosDir}/snap_${timestamp}.jpg`;
    let photoData = buffer.from(readResult.base64, 'base64');
    let pf: fileIo.File = fileIo.openSync(persistPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
    fileIo.writeSync(pf.fd, photoData.buffer);
    fileIo.closeSync(pf);
    this.log.info(TAG, `Photo saved to: ${persistPath}`);

    return `{"format":"jpg","base64":${JSON.stringify(readResult.base64)},"width":${readResult.width},"height":${readResult.height},"filePath":${JSON.stringify(persistPath)}}`;
  }

  /**
   * Auto-capture photo using Camera Kit API directly (no system camera UI).
   * Flow: open camera → start session → wait for AE → capture → readLatestImage → save JPEG.
   */
  async autoCapture(facing: string, destPath: string): Promise<string> {
    let ctx = this.appContext!;

    // Request camera permission (direct Camera Kit API doesn't auto-prompt)
    let atManager = abilityAccessCtrl.createAtManager();
    let permResult = await atManager.requestPermissionsFromUser(
      ctx as common.UIAbilityContext, ['ohos.permission.CAMERA']);
    if (permResult.authResults[0] !== 0) {
      throw new Error('Camera permission denied');
    }

    let mgr = camera.getCameraManager(ctx);
    let cameras: camera.CameraDevice[] = mgr.getSupportedCameras();
    if (cameras.length === 0) {
      throw new Error('No camera available');
    }

    // Select camera by facing direction
    let targetPos: camera.CameraPosition = facing === 'front'
      ? camera.CameraPosition.CAMERA_POSITION_FRONT
      : camera.CameraPosition.CAMERA_POSITION_BACK;
    let dev: camera.CameraDevice = cameras[0];
    for (let c of cameras) {
      if (c.cameraPosition === targetPos) { dev = c; break; }
    }
    this.log.info(TAG, `autoCapture: camera=${dev.cameraId} facing=${facing}`);

    let cap: camera.CameraOutputCapability =
      mgr.getSupportedOutputCapability(dev, camera.SceneMode.NORMAL_PHOTO);

    // Pick the largest photo profile with max dimension <= 2560 (reasonable for ImageReceiver)
    // Falls back to the overall largest if none in range
    let photoProfile: camera.Profile = cap.photoProfiles[0];
    let bestInRange: camera.Profile | null = null;
    let largest: camera.Profile = cap.photoProfiles[0];
    for (let p of cap.photoProfiles) {
      let maxDim = Math.max(p.size.width, p.size.height);
      let area = p.size.width * p.size.height;
      // Track overall largest
      if (area > largest.size.width * largest.size.height) {
        largest = p;
      }
      // Track best in range [1280, 2560]
      if (maxDim >= 1280 && maxDim <= 2560) {
        if (!bestInRange || area > bestInRange.size.width * bestInRange.size.height) {
          bestInRange = p;
        }
      }
    }
    photoProfile = bestInRange ?? largest;

    // Pick a matching preview profile (closest to 1080p)
    let previewProfile: camera.Profile = cap.previewProfiles[0];
    for (let p of cap.previewProfiles) {
      let curDiff = Math.abs(previewProfile.size.width - 1920);
      let newDiff = Math.abs(p.size.width - 1920);
      if (newDiff < curDiff) {
        previewProfile = p;
      }
    }
    this.log.info(TAG, `autoCapture: photo=${photoProfile.size.width}x${photoProfile.size.height} preview=${previewProfile.size.width}x${previewProfile.size.height}`);

    // Create preview surface (required by camera session, use JPEG format for ImageReceiver)
    let previewReceiver: image.ImageReceiver = image.createImageReceiver(
      previewProfile.size.width, previewProfile.size.height, 2000, 8);
    let previewSurfaceId: string = await previewReceiver.getReceivingSurfaceId();
    let previewOutput: camera.PreviewOutput = mgr.createPreviewOutput(previewProfile, previewSurfaceId);

    // Create photo receiver + output
    let photoReceiver: image.ImageReceiver = image.createImageReceiver(
      photoProfile.size.width, photoProfile.size.height, 2000, 8);
    let photoSurfaceId: string = await photoReceiver.getReceivingSurfaceId();
    let photoOutput: camera.PhotoOutput = mgr.createPhotoOutput(photoProfile, photoSurfaceId);

    // Open camera input
    let cameraInput: camera.CameraInput = mgr.createCameraInput(dev);
    await cameraInput.open();

    // Configure and start session
    let session: camera.PhotoSession = mgr.createSession(camera.SceneMode.NORMAL_PHOTO) as camera.PhotoSession;
    session.beginConfig();
    session.addInput(cameraInput);
    session.addOutput(previewOutput);
    session.addOutput(photoOutput);
    await session.commitConfig();
    await session.start();
    this.log.info(TAG, 'autoCapture: session started, waiting for AE...');

    // Wait for auto-exposure/focus to settle
    await new Promise<void>((r) => { setTimeout(r, 2000); });

    // Trigger capture
    let captureSettings: camera.PhotoCaptureSetting = {
      quality: camera.QualityLevel.QUALITY_LEVEL_HIGH,
      rotation: camera.ImageRotation.ROTATION_0,
    };
    await photoOutput.capture(captureSettings);
    this.log.info(TAG, 'autoCapture: capture triggered');

    // Wait for photo processing then read from receiver
    // (imageArrival callback doesn't fire in API 12, but readLatestImage works)
    await new Promise<void>((r) => { setTimeout(r, 3000); });

    let img: image.Image = await photoReceiver.readLatestImage();
    let comp: image.Component = await img.getComponent(image.ComponentType.JPEG);
    this.log.info(TAG, `autoCapture: JPEG ${comp.byteBuffer.byteLength} bytes`);

    if (comp.byteBuffer.byteLength === 0) {
      img.release();
      throw new Error('Auto-capture: empty JPEG data');
    }

    let f: fileIo.File = fileIo.openSync(destPath,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
    fileIo.writeSync(f.fd, comp.byteBuffer);
    fileIo.closeSync(f);
    img.release();

    this.log.info(TAG, `autoCapture: saved ${comp.byteBuffer.byteLength} bytes to ${destPath}`);

    // Cleanup camera resources
    try { await session.stop(); } catch { /* ignore */ }
    try { session.release(); } catch { /* ignore */ }
    try { await cameraInput.close(); } catch { /* ignore */ }
    try { photoOutput.release(); } catch { /* ignore */ }
    try { previewOutput.release(); } catch { /* ignore */ }
    try { previewReceiver.release(); } catch { /* ignore */ }
    try { photoReceiver.release(); } catch { /* ignore */ }

    return destPath;
  }

  // ---- camera.clip ----

  private async clip(paramsJson: string | undefined): Promise<string> {
    if (!this.appContext) {
      throw new Error('Context not set');
    }

    let facing: string = 'back';
    let durationMs: number = 15000;

    if (paramsJson && paramsJson.length > 0) {
      try {
        let p = JSON.parse(paramsJson) as Record<string, Object>;
        if (p['facing'] !== undefined) facing = p['facing'] as string;
        if (p['durationMs'] !== undefined) durationMs = Math.max(1000, Math.min(60000, p['durationMs'] as number));
      } catch { /* defaults */ }
    }

    let savePath = `${this.appContext.cacheDir}/clip_${Date.now()}.mp4`;
    let saveUri = `file://${savePath}`;

    this.log.info(TAG, `clip: facing=${facing} duration=${durationMs}ms saveUri=${saveUri}`);

    let pickerProfile: cameraPicker.PickerProfile = {
      cameraPosition: facing === 'front'
        ? camera.CameraPosition.CAMERA_POSITION_FRONT
        : camera.CameraPosition.CAMERA_POSITION_BACK,
      saveUri: saveUri,
      videoDuration: Math.round(durationMs / 1000),
    };

    let result: cameraPicker.PickerResult =
      await cameraPicker.pick(this.appContext,
        [cameraPicker.PickerMediaType.VIDEO], pickerProfile);

    this.log.info(TAG, `Picker done: code=${result.resultCode} uri="${result.resultUri}" type=${result.mediaType}`);

    if (result.resultCode !== 0) {
      throw new Error(`Camera picker cancelled (code=${result.resultCode})`);
    }

    let readResult = this.tryReadFile(result.resultUri, savePath);
    this.log.info(TAG, `Video: ${readResult.size} bytes`);

    return `{"format":"mp4","base64":${JSON.stringify(readResult.base64)},"durationMs":${durationMs},"hasAudio":true}`;
  }

  /**
   * Compress photo to fit within WebSocket frame limits.
   * Resizes to max 1280px and re-encodes as JPEG quality 75.
   * Falls back to raw read if compression fails.
   */
  private async compressAndEncode(resultUri: string, savePath: string): Promise<FileReadResult> {
    let file: fileIo.File | undefined;
    let openedPath: string = '';

    // Try to open the file using multiple strategies
    let paths: string[] = [savePath];
    if (resultUri.length > 0) {
      paths.push(resultUri);
    }
    if (resultUri.startsWith('file://')) {
      paths.push(resultUri.substring(7));
    }

    for (let i = 0; i < paths.length; i++) {
      try {
        file = fileIo.openSync(paths[i], fileIo.OpenMode.READ_ONLY);
        openedPath = paths[i];
        this.log.info(TAG, `compress: opened "${paths[i]}" fd=${file.fd}`);
        break;
      } catch { /* try next */ }
    }

    if (!file) {
      this.log.warn(TAG, 'compress: could not open file, falling back to raw read');
      return this.tryReadFile(resultUri, savePath);
    }

    try {
      let imageSource = image.createImageSource(file.fd);
      let info = await imageSource.getImageInfo();
      let origW = info.size.width;
      let origH = info.size.height;

      // Scale down to max 1280px on longest side
      let maxDim = 1280;
      let targetW = origW;
      let targetH = origH;
      if (origW > maxDim || origH > maxDim) {
        if (origW >= origH) {
          targetW = maxDim;
          targetH = Math.round(origH * maxDim / origW);
        } else {
          targetH = maxDim;
          targetW = Math.round(origW * maxDim / origH);
        }
      }

      this.log.info(TAG, `compress: ${origW}x${origH} -> ${targetW}x${targetH}`);

      let decodingOptions: image.DecodingOptions = {
        desiredSize: { width: targetW, height: targetH }
      };
      let pixelMap = await imageSource.createPixelMap(decodingOptions);

      let packer = image.createImagePacker();
      let packOptions: image.PackingOption = { format: 'image/jpeg', quality: 75 };
      let packed: ArrayBuffer = await packer.packing(pixelMap, packOptions);

      this.log.info(TAG, `compress done: ${origW}x${origH} -> ${targetW}x${targetH} = ${packed.byteLength} bytes`);

      // Clean up image resources
      await pixelMap.release();
      imageSource.release();
      packer.release();
      fileIo.closeSync(file);

      // Clean up temp files
      try { fileIo.unlinkSync(openedPath); } catch { /* best effort */ }

      let result = new FileReadResult();
      result.base64 = buffer.from(packed).toString('base64');
      result.size = packed.byteLength;
      result.width = targetW;
      result.height = targetH;
      return result;
    } catch (err) {
      this.log.warn(TAG, `compress failed: ${(err as Error).message ?? ''}, falling back to raw read`);
      try { fileIo.closeSync(file); } catch { /* ignore */ }
      return this.tryReadFile(resultUri, savePath);
    }
  }

  /**
   * Try multiple strategies to read the captured file.
   * Strategy 1: Open savePath directly as file path
   * Strategy 2: Open resultUri as URI string (handles datashare://, file://, etc.)
   * Strategy 3: Strip file:// prefix from resultUri and open as path
   */
  private tryReadFile(resultUri: string, savePath: string): FileReadResult {
    // Strategy 1: savePath directly
    this.log.info(TAG, `tryRead strategy 1: savePath="${savePath}"`);
    try {
      return this.readFromPath(savePath);
    } catch (e1) {
      this.log.warn(TAG, `strategy 1 failed: ${(e1 as Error).message ?? ''}`);
    }

    // Strategy 2: resultUri as-is (fileIo can handle URI strings)
    if (resultUri.length > 0) {
      this.log.info(TAG, `tryRead strategy 2: resultUri="${resultUri}"`);
      try {
        return this.readFromPath(resultUri);
      } catch (e2) {
        this.log.warn(TAG, `strategy 2 failed: ${(e2 as Error).message ?? ''}`);
      }
    }

    // Strategy 3: strip file:// from resultUri
    if (resultUri.startsWith('file://')) {
      let stripped = resultUri.substring(7);
      this.log.info(TAG, `tryRead strategy 3: stripped="${stripped}"`);
      try {
        return this.readFromPath(stripped);
      } catch (e3) {
        this.log.warn(TAG, `strategy 3 failed: ${(e3 as Error).message ?? ''}`);
      }
    }

    throw new Error(`All read strategies failed. resultUri="${resultUri}" savePath="${savePath}"`);
  }

  private readFromPath(pathOrUri: string): FileReadResult {
    let file = fileIo.openSync(pathOrUri, fileIo.OpenMode.READ_ONLY);
    try {
      // Get size: try stat with path first, then read in chunks as fallback
      let fileSize = 0;
      try {
        let stat = fileIo.statSync(pathOrUri);
        fileSize = stat.size;
      } catch {
        // statSync with path failed, try with fd
        try {
          let stat = fileIo.statSync(file.fd);
          fileSize = stat.size;
        } catch {
          // Both failed — read in chunks
          this.log.warn(TAG, `stat failed for "${pathOrUri}", reading in chunks`);
          return this.readInChunks(file);
        }
      }

      this.log.info(TAG, `File size: ${fileSize} bytes`);
      let buf = new ArrayBuffer(fileSize);
      fileIo.readSync(file.fd, buf);
      fileIo.closeSync(file);

      let result = new FileReadResult();
      result.base64 = buffer.from(buf).toString('base64');
      result.size = fileSize;

      // Clean up
      try { fileIo.unlinkSync(pathOrUri); } catch { /* best effort */ }

      return result;
    } catch (err) {
      try { fileIo.closeSync(file); } catch { /* ignore */ }
      throw err as Error;
    }
  }

  /**
   * Fallback: read file in 1MB chunks when we can't determine size upfront.
   */
  private readInChunks(file: fileIo.File): FileReadResult {
    let chunks: ArrayBuffer[] = [];
    let totalSize = 0;
    let chunkSize = 1024 * 1024; // 1MB

    while (true) {
      let chunk = new ArrayBuffer(chunkSize);
      let bytesRead = fileIo.readSync(file.fd, chunk);
      if (bytesRead <= 0) break;

      if (bytesRead < chunkSize) {
        chunks.push(chunk.slice(0, bytesRead));
      } else {
        chunks.push(chunk);
      }
      totalSize += bytesRead;

      if (bytesRead < chunkSize) break;
    }
    fileIo.closeSync(file);

    // Combine chunks
    let combined = new ArrayBuffer(totalSize);
    let view = new Uint8Array(combined);
    let offset = 0;
    for (let i = 0; i < chunks.length; i++) {
      let chunkView = new Uint8Array(chunks[i]);
      view.set(chunkView, offset);
      offset += chunkView.byteLength;
    }

    let result = new FileReadResult();
    result.base64 = buffer.from(combined).toString('base64');
    result.size = totalSize;
    this.log.info(TAG, `Read in chunks: ${totalSize} bytes from ${chunks.length} chunks`);
    return result;
  }
}

class FileReadResult {
  base64: string = '';
  size: number = 0;
  width: number = 0;
  height: number = 0;
}
