/**
 * Generates and persists an Ed25519 device identity.
 * Device ID = SHA-256(publicKeyRaw) as hex string.
 * Ported from Android DeviceIdentityStore.kt.
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { Constants } from '../../common/Constants';
import { LogService } from '../../common/LogService';

const TAG = 'DeviceIdentity';

export interface DeviceIdentity {
  deviceId: string;
  publicKeyB64: string;
  privateKeyB64: string;
  createdAtMs: number;
}

export class DeviceIdentityStore {
  private identity: DeviceIdentity | undefined = undefined;
  private keyPair: cryptoFramework.KeyPair | undefined = undefined;
  private log: LogService = LogService.getInstance();

  async loadOrCreate(context: common.UIAbilityContext): Promise<DeviceIdentity> {
    if (this.identity) {
      this.log.debug(TAG, `Returning cached identity: deviceId=${this.identity.deviceId.substring(0, 12)}...`);
      return this.identity;
    }

    this.log.info(TAG, 'Loading device identity from preferences...');
    let store = await preferences.getPreferences(context, Constants.PREFS_DEVICE_IDENTITY);
    let saved = (await store.get('identity', '')) as string;
    if (saved.length > 0) {
      try {
        let parsed: DeviceIdentity = JSON.parse(saved) as DeviceIdentity;
        if (parsed.deviceId && parsed.publicKeyB64 && parsed.privateKeyB64) {
          this.identity = parsed;
          this.log.info(TAG, `Loaded existing identity: deviceId=${parsed.deviceId.substring(0, 12)}... pubKey=${parsed.publicKeyB64.substring(0, 16)}... created=${new Date(parsed.createdAtMs).toISOString()}`);
          await this.restoreKeyPair(parsed);
          return parsed;
        }
        this.log.warn(TAG, 'Saved identity missing required fields, regenerating');
      } catch {
        this.log.warn(TAG, 'Corrupt identity data in preferences, regenerating');
      }
    } else {
      this.log.info(TAG, 'No saved identity found, generating new one');
    }

    let fresh = await this.generate();
    this.log.info(TAG, `Generated new identity: deviceId=${fresh.deviceId.substring(0, 12)}... hasPubKey=${fresh.publicKeyB64.length > 0}`);
    await store.put('identity', JSON.stringify(fresh));
    await store.flush();
    this.identity = fresh;
    return fresh;
  }

  async signPayload(payload: string): Promise<string> {
    let kp = this.keyPair;
    if (!kp) {
      this.log.warn(TAG, 'signPayload: no keyPair available, returning empty');
      return '';
    }
    try {
      this.log.debug(TAG, `signPayload: signing ${payload.length} chars`);
      let signer = cryptoFramework.createSign('Ed25519');
      await signer.init(kp.priKey);
      let encoder = new util.TextEncoder();
      let data: cryptoFramework.DataBlob = { data: encoder.encodeInto(payload) };
      let sig = await signer.sign(data);
      let result = this.uint8ArrayToBase64Url(sig.data);
      this.log.debug(TAG, `signPayload: signature=${result.substring(0, 16)}... (${result.length} chars)`);
      return result;
    } catch (err) {
      let msg = (err as Error).message ?? 'unknown';
      this.log.error(TAG, `signPayload failed: ${msg}`);
      return '';
    }
  }

  getPublicKeyBase64Url(): string {
    if (!this.identity) {
      this.log.warn(TAG, 'getPublicKeyBase64Url: no identity loaded');
      return '';
    }
    try {
      let raw = this.base64ToUint8Array(this.identity.publicKeyB64);
      let result = this.uint8ArrayToBase64Url(raw);
      this.log.debug(TAG, `getPublicKeyBase64Url: ${result.substring(0, 16)}...`);
      return result;
    } catch {
      this.log.error(TAG, 'getPublicKeyBase64Url: conversion failed');
      return '';
    }
  }

  getDeviceId(): string {
    return this.identity?.deviceId ?? '';
  }

  private async generate(): Promise<DeviceIdentity> {
    try {
      this.log.info(TAG, 'Generating Ed25519 keypair...');
      let generator = cryptoFramework.createAsyKeyGenerator('Ed25519');
      let kp = await generator.generateKeyPair();
      this.keyPair = kp;

      let pubBlob = kp.pubKey.getEncoded();
      let priBlob = kp.priKey.getEncoded();

      this.log.debug(TAG, `Raw pubKey blob: ${pubBlob.data.length} bytes, priKey blob: ${priBlob.data.length} bytes`);

      // Strip SPKI prefix from public key to get raw 32-byte key
      let rawPub = this.stripSpkiPrefix(pubBlob.data);
      this.log.debug(TAG, `Raw pub after SPKI strip: ${rawPub.length} bytes`);

      let deviceId = await this.sha256Hex(rawPub);
      this.log.info(TAG, `Ed25519 keypair generated successfully, deviceId=${deviceId.substring(0, 12)}...`);

      return {
        deviceId: deviceId,
        publicKeyB64: this.uint8ArrayToBase64(rawPub),
        privateKeyB64: this.uint8ArrayToBase64(priBlob.data),
        createdAtMs: Date.now(),
      };
    } catch (err) {
      let msg = (err as Error).message ?? 'unknown';
      this.log.warn(TAG, `Ed25519 generation failed: ${msg}. Falling back to random deviceId`);
      // Ed25519 not available: use random device ID
      let randomId = await this.randomHex(32);
      return {
        deviceId: randomId,
        publicKeyB64: '',
        privateKeyB64: '',
        createdAtMs: Date.now(),
      };
    }
  }

  private async restoreKeyPair(identity: DeviceIdentity): Promise<void> {
    if (!identity.privateKeyB64 || !identity.publicKeyB64) {
      this.log.warn(TAG, 'restoreKeyPair: missing pub/pri key, skipping');
      return;
    }
    try {
      this.log.debug(TAG, 'Restoring Ed25519 keypair from stored keys...');
      let generator = cryptoFramework.createAsyKeyGenerator('Ed25519');
      let rawPub = this.base64ToUint8Array(identity.publicKeyB64);
      let priBytes = this.base64ToUint8Array(identity.privateKeyB64);
      // Re-wrap raw pub with SPKI prefix for API
      let spkiPub = this.addSpkiPrefix(rawPub);
      this.log.debug(TAG, `restoreKeyPair: rawPub=${rawPub.length}B spkiPub=${spkiPub.length}B pri=${priBytes.length}B`);
      let pubBlob: cryptoFramework.DataBlob = { data: spkiPub };
      let priBlob: cryptoFramework.DataBlob = { data: priBytes };
      this.keyPair = await generator.convertKey(pubBlob, priBlob);
      this.log.info(TAG, 'Keypair restored successfully');
    } catch (err) {
      let msg = (err as Error).message ?? 'unknown';
      this.log.error(TAG, `restoreKeyPair failed: ${msg}`);
      this.keyPair = undefined;
    }
  }

  // Ed25519 SPKI prefix: 302a300506032b6570032100
  private static readonly SPKI_PREFIX: number[] = [
    0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00
  ];

  private stripSpkiPrefix(spki: Uint8Array): Uint8Array {
    let prefix = DeviceIdentityStore.SPKI_PREFIX;
    if (spki.length === prefix.length + 32) {
      let match = true;
      for (let i = 0; i < prefix.length; i++) {
        if (spki[i] !== prefix[i]) {
          match = false;
          break;
        }
      }
      if (match) {
        return spki.slice(prefix.length);
      }
    }
    return spki;
  }

  private addSpkiPrefix(raw: Uint8Array): Uint8Array {
    if (raw.length !== 32) {
      return raw;
    }
    let prefix = DeviceIdentityStore.SPKI_PREFIX;
    let out = new Uint8Array(prefix.length + 32);
    for (let i = 0; i < prefix.length; i++) {
      out[i] = prefix[i];
    }
    out.set(raw, prefix.length);
    return out;
  }

  private async sha256Hex(data: Uint8Array): Promise<string> {
    let md = cryptoFramework.createMd('SHA256');
    await md.update({ data: data });
    let digest = await md.digest();
    return this.uint8ArrayToHex(digest.data);
  }

  private async randomHex(bytes: number): Promise<string> {
    let random = cryptoFramework.createRandom();
    let blob = await random.generateRandom(bytes);
    return this.uint8ArrayToHex(blob.data);
  }

  private uint8ArrayToHex(arr: Uint8Array): string {
    let hex = '';
    for (let i = 0; i < arr.length; i++) {
      let byte = arr[i];
      hex += (byte < 16 ? '0' : '') + byte.toString(16);
    }
    return hex;
  }

  private uint8ArrayToBase64(arr: Uint8Array): string {
    let helper = new util.Base64Helper();
    return helper.encodeToStringSync(arr);
  }

  private uint8ArrayToBase64Url(arr: Uint8Array): string {
    let b64 = this.uint8ArrayToBase64(arr);
    return b64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }

  private base64ToUint8Array(b64: string): Uint8Array {
    let helper = new util.Base64Helper();
    return helper.decodeSync(b64);
  }

  buildAuthPayload(
    deviceId: string, clientId: string, clientMode: string,
    role: string, scopes: string[], signedAtMs: number,
    token: string | undefined, nonce: string | undefined
  ): string {
    let scopeStr = scopes.join(',');
    let authToken = token ?? '';
    let version = (!nonce || nonce.length === 0) ? 'v1' : 'v2';
    let parts: string[] = [version, deviceId, clientId, clientMode, role, scopeStr, signedAtMs.toString(), authToken];
    if (nonce && nonce.length > 0) {
      parts.push(nonce);
    }
    let payload = parts.join('|');
    this.log.debug(TAG, `buildAuthPayload: version=${version} deviceId=${deviceId.substring(0, 12)}... clientId=${clientId} role=${role} nonce=${nonce ? nonce.substring(0, 8) + '...' : 'none'}`);
    return payload;
  }
}
