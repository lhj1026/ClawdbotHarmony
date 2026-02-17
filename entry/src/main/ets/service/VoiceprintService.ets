/**
 * VoiceprintService - Speaker identification using sherpa-onnx.
 *
 * Provides:
 * - Speaker enrollment (register voice samples)
 * - Speaker identification (1:N search)
 * - Speaker verification (1:1 match)
 *
 * All processing is local, no network required.
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { resourceManager } from '@kit.LocalizationKit';
import {
  SpeakerEmbeddingExtractor,
  SpeakerEmbeddingExtractorConfig,
  SpeakerEmbeddingManager,
  OnlineStream
} from 'sherpa_onnx';

const TAG = '[VoiceprintService]';
const PREFS_NAME = 'voiceprint_db';
const PROFILES_KEY = 'voiceprint_profiles';

// Model filename (in rawfile/voiceprint/)
const MODEL_FILE = 'voiceprint/3dspeaker_speech_eres2net_base_200k_sv_zh-cn_16k-common.onnx';

export interface VoiceprintProfile {
  name: string;
  enrolledAt: number;
  sampleCount: number;
  embedding: number[];
}

interface VoiceprintStore {
  speakers: VoiceprintProfile[];
  version: number;
}

export interface IdentifyResult {
  speaker: string;
  score: number;
  confidence: 'high' | 'medium' | 'low' | 'unknown';
}

interface VerifyResult {
  match: boolean;
  score: number;
}

export class VoiceprintService {
  private static instance: VoiceprintService | null = null;
  private initialized: boolean = false;
  private store: preferences.Preferences | null = null;
  private profiles: VoiceprintProfile[] = [];

  // sherpa-onnx components
  private extractor: SpeakerEmbeddingExtractor | null = null;
  private manager: SpeakerEmbeddingManager | null = null;
  private resourceManager: resourceManager.ResourceManager | null = null;

  // Thresholds
  private readonly IDENTIFY_THRESHOLD = 0.5;
  private readonly HIGH_CONFIDENCE = 0.75;
  private readonly MEDIUM_CONFIDENCE = 0.6;
  private readonly LOW_CONFIDENCE = 0.45;
  private readonly MIN_DURATION_SEC = 0.5;

  static getInstance(): VoiceprintService {
    if (!VoiceprintService.instance) {
      VoiceprintService.instance = new VoiceprintService();
    }
    return VoiceprintService.instance;
  }

  isInitialized(): boolean {
    return this.initialized;
  }

  async init(context: common.UIAbilityContext): Promise<boolean> {
    if (this.initialized) return true;

    try {
      this.store = await preferences.getPreferences(context, PREFS_NAME);
      this.resourceManager = context.resourceManager;

      // Initialize sherpa-onnx extractor
      const config = new SpeakerEmbeddingExtractorConfig();
      config.model = MODEL_FILE;
      config.numThreads = 2;
      config.debug = false;

      this.extractor = new SpeakerEmbeddingExtractor(config, this.resourceManager);

      if (!this.extractor) {
        console.error(TAG, 'Failed to create SpeakerEmbeddingExtractor');
        return false;
      }

      const dim = this.extractor.dim;
      console.info(TAG, `Extractor loaded. Embedding dim: ${dim}`);

      // Create speaker manager
      this.manager = new SpeakerEmbeddingManager(dim);

      // Restore persisted profiles
      await this.restoreProfiles();

      this.initialized = true;
      console.info(TAG, `Initialized. ${this.profiles.length} speaker(s) loaded.`);
      return true;
    } catch (e) {
      console.error(TAG, `Init failed: ${(e as BusinessError).message}`);
      return false;
    }
  }

  extractEmbedding(samples: Float32Array, sampleRate: number): Float32Array | null {
    if (!this.initialized || !this.extractor) {
      console.error(TAG, 'Service not initialized');
      return null;
    }

    const duration = samples.length / sampleRate;
    if (duration < this.MIN_DURATION_SEC) {
      console.warn(TAG, `Audio too short: ${duration.toFixed(2)}s`);
      return null;
    }

    try {
      const stream: OnlineStream = this.extractor.createStream();
      stream.acceptWaveform({ samples, sampleRate });
      const embedding = this.extractor.compute(stream);
      return embedding;
    } catch (e) {
      const err = e as BusinessError;
      console.error(TAG, `extractEmbedding error: ${err.message}`);
      return null;
    }
  }

  async enrollSpeaker(name: string, audioSamples: Float32Array[], sampleRate: number = 16000): Promise<boolean> {
    if (!this.initialized || !this.manager) return false;
    if (audioSamples.length === 0) return false;

    try {
      const embeddings: Float32Array[] = [];
      for (const samples of audioSamples) {
        const emb = this.extractEmbedding(samples, sampleRate);
        if (emb && emb.length > 0) {
          embeddings.push(emb);
        }
      }

      if (embeddings.length === 0) {
        console.error(TAG, 'No valid embeddings extracted');
        return false;
      }

      // Remove existing if any
      if (this.manager.contains(name)) {
        this.manager.remove(name);
      }

      // Use the first embedding (or average them)
      const avgEmb = this.averageEmbeddings(embeddings);

      // Add to manager
      const ok = this.manager.add({ name, v: avgEmb });
      if (!ok) {
        console.error(TAG, `Failed to add speaker "${name}" to manager`);
        return false;
      }

      // Save profile
      const profile: VoiceprintProfile = {
        name: name,
        enrolledAt: Date.now(),
        sampleCount: embeddings.length,
        embedding: Array.from(avgEmb),
      };

      this.profiles = this.profiles.filter((p) => p.name !== name);
      this.profiles.push(profile);
      await this.saveProfiles();

      console.info(TAG, `Enrolled speaker "${name}" with ${embeddings.length} sample(s)`);
      return true;
    } catch (e) {
      const err = e as BusinessError;
      console.error(TAG, `enrollSpeaker error: ${err.message}`);
      return false;
    }
  }

  identify(samples: Float32Array, sampleRate: number = 16000, threshold?: number): IdentifyResult {
    const unknown: IdentifyResult = { speaker: '', score: 0, confidence: 'unknown' };
    if (!this.initialized || !this.manager) return unknown;

    const actualThreshold = threshold ?? this.IDENTIFY_THRESHOLD;

    try {
      const embedding = this.extractEmbedding(samples, sampleRate);
      if (!embedding || embedding.length === 0) return unknown;

      // Search for matching speaker
      const matchName = this.manager.search({ threshold: actualThreshold, v: embedding });

      if (!matchName || matchName === '') return unknown;

      // Calculate score by comparing with stored embedding
      const profile = this.profiles.find((p) => p.name === matchName);
      let score = actualThreshold; // Default to threshold if we can't calculate

      if (profile && profile.embedding.length > 0) {
        const storedEmb = new Float32Array(profile.embedding);
        score = this.cosineSimilarity(embedding, storedEmb);
      }

      let confidence: 'high' | 'medium' | 'low' | 'unknown';
      if (score >= this.HIGH_CONFIDENCE) {
        confidence = 'high';
      } else if (score >= this.MEDIUM_CONFIDENCE) {
        confidence = 'medium';
      } else if (score >= this.LOW_CONFIDENCE) {
        confidence = 'low';
      } else {
        confidence = 'unknown';
      }

      return { speaker: matchName, score, confidence };
    } catch (e) {
      const err = e as BusinessError;
      console.error(TAG, `identify error: ${err.message}`);
      return unknown;
    }
  }

  verify(name: string, samples: Float32Array, sampleRate: number = 16000, threshold?: number): VerifyResult {
    const fail: VerifyResult = { match: false, score: 0 };
    if (!this.initialized || !this.manager) return fail;

    const actualThreshold = threshold ?? this.MEDIUM_CONFIDENCE;

    try {
      const embedding = this.extractEmbedding(samples, sampleRate);
      if (!embedding || embedding.length === 0) return fail;

      // Verify using stored embedding
      const profile = this.profiles.find((p) => p.name === name);
      if (!profile || !profile.embedding || profile.embedding.length === 0) {
        return fail;
      }

      const storedEmb = new Float32Array(profile.embedding);
      const score = this.cosineSimilarity(embedding, storedEmb);
      const match = score >= actualThreshold;

      return { match, score };
    } catch (e) {
      const err = e as BusinessError;
      console.error(TAG, `verify error: ${err.message}`);
      return fail;
    }
  }

  async removeSpeaker(name: string): Promise<boolean> {
    if (!this.initialized || !this.manager) return false;

    try {
      this.manager.remove(name);
      this.profiles = this.profiles.filter((p) => p.name !== name);
      await this.saveProfiles();
      console.info(TAG, `Removed speaker "${name}"`);
      return true;
    } catch (e) {
      const err = e as BusinessError;
      console.error(TAG, `removeSpeaker error: ${err.message}`);
      return false;
    }
  }

  listSpeakers(): VoiceprintProfile[] {
    return this.profiles.slice();
  }

  getAllSpeakerNames(): string[] {
    if (!this.initialized || !this.manager) return [];
    return this.manager.getAllSpeakerNames();
  }

  getSpeakerCount(): number {
    return this.profiles.length;
  }

  containsSpeaker(name: string): boolean {
    if (!this.initialized || !this.manager) return false;
    return this.manager.contains(name);
  }

  getEmbeddingDim(): number {
    if (!this.initialized || !this.extractor) return 0;
    return this.extractor.dim;
  }

  // ---- Private Methods ----

  private cosineSimilarity(a: Float32Array, b: Float32Array): number {
    if (a.length !== b.length) return 0;

    let dot = 0, normA = 0, normB = 0;
    for (let i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }

    if (normA > 0 && normB > 0) {
      return dot / (Math.sqrt(normA) * Math.sqrt(normB));
    }
    return 0;
  }

  private averageEmbeddings(embeddings: Float32Array[]): Float32Array {
    if (embeddings.length === 0) return new Float32Array(0);

    const dim = embeddings[0].length;
    const avg = new Float32Array(dim);

    for (const emb of embeddings) {
      for (let i = 0; i < dim; i++) {
        avg[i] += emb[i];
      }
    }

    for (let i = 0; i < dim; i++) {
      avg[i] /= embeddings.length;
    }

    return avg;
  }

  private async saveProfiles(): Promise<void> {
    if (!this.store) return;
    const data: VoiceprintStore = {
      speakers: this.profiles,
      version: 1,
    };
    await this.store.put(PROFILES_KEY, JSON.stringify(data));
    await this.store.flush();
  }

  private async restoreProfiles(): Promise<void> {
    if (!this.store || !this.manager) return;

    try {
      const raw = await this.store.get(PROFILES_KEY, '') as string;
      if (!raw || raw.length === 0) {
        this.profiles = [];
        return;
      }

      const data = JSON.parse(raw) as VoiceprintStore;
      this.profiles = data.speakers || [];

      // Restore each speaker into manager
      for (const profile of this.profiles) {
        if (profile.embedding && profile.embedding.length > 0) {
          const emb = new Float32Array(profile.embedding);
          this.manager.add({ name: profile.name, v: emb });
        }
      }

      console.info(TAG, `Restored ${this.profiles.length} speaker profile(s)`);
    } catch (e) {
      const err = e as BusinessError;
      console.error(TAG, `restoreProfiles error: ${err.message}`);
      this.profiles = [];
    }
  }
}
