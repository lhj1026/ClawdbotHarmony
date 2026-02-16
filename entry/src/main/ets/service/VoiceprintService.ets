/**
 * VoiceprintService - Speaker identification using sherpa_onnx.
 *
 * Uses official sherpa_onnx HarmonyOS package for:
 * - Speaker enrollment (register voice samples)
 * - Speaker identification (1:N search)
 * - Speaker verification (1:1 match)
 *
 * All processing is local, no network required.
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import {
  OnlineStream,
  SpeakerEmbeddingExtractor,
  SpeakerEmbeddingExtractorConfig,
  SpeakerEmbeddingManager
} from 'sherpa_onnx';

const TAG = '[VoiceprintService]';
const PREFS_NAME = 'voiceprint_db';
const PROFILES_KEY = 'voiceprint_profiles';

// Model file in rawfile/voiceprint/
const MODEL_FILENAME = 'voiceprint/3dspeaker_speech_eres2net_base_200k_sv_zh-cn_16k-common.onnx';

export interface VoiceprintProfile {
  name: string;
  enrolledAt: number;
  sampleCount: number;
  embedding: number[];  // Persisted as JSON array
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

export interface Samples {
  samples: Float32Array;
  sampleRate: number;
}

export class VoiceprintService {
  private static instance: VoiceprintService | null = null;
  private initialized: boolean = false;
  private store: preferences.Preferences | null = null;
  private profiles: VoiceprintProfile[] = [];

  private extractor: SpeakerEmbeddingExtractor | null = null;
  private manager: SpeakerEmbeddingManager | null = null;

  // Thresholds (adjust based on testing)
  private readonly IDENTIFY_THRESHOLD = 0.5;
  private readonly HIGH_CONFIDENCE = 0.75;
  private readonly MEDIUM_CONFIDENCE = 0.6;
  private readonly LOW_CONFIDENCE = 0.45;
  private readonly MIN_DURATION_SEC = 0.5;  // Minimum audio duration

  static getInstance(): VoiceprintService {
    if (!VoiceprintService.instance) {
      VoiceprintService.instance = new VoiceprintService();
    }
    return VoiceprintService.instance;
  }

  isInitialized(): boolean {
    return this.initialized;
  }

  /**
   * Initialize the service with context.
   * Must be called before any other methods.
   */
  async init(context: common.UIAbilityContext): Promise<boolean> {
    if (this.initialized) return true;

    try {
      // 1. Load Preferences store
      this.store = await preferences.getPreferences(context, PREFS_NAME);

      // 2. Initialize speaker embedding extractor
      const config = new SpeakerEmbeddingExtractorConfig();
      config.model = MODEL_FILENAME;
      config.numThreads = 2;
      config.debug = false;

      this.extractor = new SpeakerEmbeddingExtractor(config, context.resourceManager);
      if (!this.extractor) {
        console.error(TAG, 'Failed to create SpeakerEmbeddingExtractor');
        return false;
      }

      // 3. Create speaker manager
      const dim = this.extractor.dim;
      console.info(TAG, `Embedding dimension: ${dim}`);
      this.manager = new SpeakerEmbeddingManager(dim);

      // 4. Restore persisted profiles
      await this.restoreProfiles();

      this.initialized = true;
      console.info(TAG, `Initialized. ${this.profiles.length} speaker(s) loaded.`);
      return true;
    } catch (e) {
      console.error(TAG, 'Init failed:', (e as Error).message ?? String(e));
      return false;
    }
  }

  /**
   * Extract embedding from audio samples.
   * Audio should be Float32Array in [-1, 1] range.
   */
  extractEmbedding(samples: Float32Array, sampleRate: number): Float32Array | null {
    if (!this.initialized || !this.extractor) {
      console.error(TAG, 'Service not initialized');
      return null;
    }

    const duration = samples.length / sampleRate;
    if (duration < this.MIN_DURATION_SEC) {
      console.warn(TAG, `Audio too short: ${duration.toFixed(2)}s (min: ${this.MIN_DURATION_SEC}s)`);
      return null;
    }

    try {
      const stream: OnlineStream = this.extractor.createStream();
      stream.acceptWaveform({ samples, sampleRate });
      const embedding = this.extractor.compute(stream);
      return embedding;
    } catch (e) {
      console.error(TAG, 'extractEmbedding error:', (e as Error).message ?? String(e));
      return null;
    }
  }

  /**
   * Enroll a new speaker with audio samples.
   * @param name Speaker name (unique identifier)
   * @param audioSamples Array of audio samples (Float32Array, [-1,1], preferably 16kHz)
   * @param sampleRate Sample rate of the audio
   */
  async enrollSpeaker(name: string, audioSamples: Float32Array[], sampleRate: number = 16000): Promise<boolean> {
    if (!this.initialized || !this.manager) return false;
    if (audioSamples.length === 0) return false;

    try {
      // Extract embeddings from each audio sample
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

      // Compute average embedding
      const avgEmbedding = this.averageEmbeddings(embeddings);

      // Remove existing speaker if any
      if (this.manager.contains(name)) {
        this.manager.remove(name);
      }

      // Add to manager
      const ok = this.manager.add({ name, v: avgEmbedding });
      if (!ok) {
        console.error(TAG, `Failed to add speaker "${name}" to manager`);
        return false;
      }

      // Create profile for persistence
      const profile: VoiceprintProfile = {
        name: name,
        enrolledAt: Date.now(),
        sampleCount: embeddings.length,
        embedding: Array.from(avgEmbedding),
      };

      // Update local profiles
      this.profiles = this.profiles.filter((p: VoiceprintProfile) => p.name !== name);
      this.profiles.push(profile);

      // Persist
      await this.saveProfiles();

      console.info(TAG, `Enrolled speaker "${name}" with ${embeddings.length} sample(s)`);
      return true;
    } catch (e) {
      console.error(TAG, 'enrollSpeaker error:', (e as Error).message ?? String(e));
      return false;
    }
  }

  /**
   * Identify speaker from audio.
   * Returns best match above threshold.
   */
  identify(samples: Float32Array, sampleRate: number = 16000, threshold?: number): IdentifyResult {
    const unknown: IdentifyResult = { speaker: '', score: 0, confidence: 'unknown' };
    if (!this.initialized || !this.manager) return unknown;

    const actualThreshold = threshold ?? this.IDENTIFY_THRESHOLD;

    try {
      const embedding = this.extractEmbedding(samples, sampleRate);
      if (!embedding || embedding.length === 0) return unknown;

      const result = this.manager.search({ threshold: actualThreshold, v: embedding });

      if (!result || result === '' || result === undefined) {
        return unknown;
      }

      // Get the actual score by computing similarity with the matched speaker
      const score = this.getSpeakerScore(result, embedding);

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

      return { speaker: result, score, confidence };
    } catch (e) {
      console.error(TAG, 'identify error:', (e as Error).message ?? String(e));
      return unknown;
    }
  }

  /**
   * Verify if audio matches a specific speaker.
   */
  verify(name: string, samples: Float32Array, sampleRate: number = 16000, threshold?: number): { match: boolean; score: number } {
    if (!this.initialized || !this.manager) {
      return { match: false, score: 0 };
    }

    const actualThreshold = threshold ?? this.MEDIUM_CONFIDENCE;

    try {
      const embedding = this.extractEmbedding(samples, sampleRate);
      if (!embedding || embedding.length === 0) {
        return { match: false, score: 0 };
      }

      const score = this.getSpeakerScore(name, embedding);
      const match = score >= actualThreshold;

      return { match, score };
    } catch (e) {
      console.error(TAG, 'verify error:', (e as Error).message ?? String(e));
      return { match: false, score: 0 };
    }
  }

  /**
   * Remove a speaker from the database.
   */
  async removeSpeaker(name: string): Promise<boolean> {
    if (!this.initialized || !this.manager) return false;

    try {
      this.manager.remove(name);
      this.profiles = this.profiles.filter((p: VoiceprintProfile) => p.name !== name);
      await this.saveProfiles();
      console.info(TAG, `Removed speaker "${name}"`);
      return true;
    } catch (e) {
      console.error(TAG, 'removeSpeaker error:', (e as Error).message ?? String(e));
      return false;
    }
  }

  /**
   * List all registered speakers.
   */
  listSpeakers(): VoiceprintProfile[] {
    return this.profiles.slice();
  }

  /**
   * Get all speaker names.
   */
  getAllSpeakerNames(): string[] {
    if (!this.manager) return [];
    return this.manager.getAllSpeakerNames();
  }

  /**
   * Get number of registered speakers.
   */
  getSpeakerCount(): number {
    return this.profiles.length;
  }

  /**
   * Check if a speaker is registered.
   */
  containsSpeaker(name: string): boolean {
    if (!this.manager) return false;
    return this.manager.contains(name);
  }

  /**
   * Get embedding dimension.
   */
  getEmbeddingDim(): number {
    if (!this.extractor) return 192;  // Default for 3dspeaker
    return this.extractor.dim;
  }

  // ---- Private Methods ----

  private getSpeakerScore(name: string, embedding: Float32Array): number {
    // Find the profile and compute cosine similarity
    const profile = this.profiles.find((p: VoiceprintProfile) => p.name === name);
    if (!profile || !profile.embedding || profile.embedding.length === 0) {
      return 0;
    }

    const stored = new Float32Array(profile.embedding);
    return this.cosineSimilarity(embedding, stored);
  }

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

      const data: VoiceprintStore = JSON.parse(raw) as VoiceprintStore;
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
      console.error(TAG, 'restoreProfiles error:', (e as Error).message ?? String(e));
      this.profiles = [];
    }
  }
}
