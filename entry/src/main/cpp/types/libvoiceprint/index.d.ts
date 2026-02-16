/**
 * Native voiceprint module - speaker embedding extraction via sherpa-onnx.
 */

/**
 * Initialize the speaker embedding model.
 * Must be called before extractEmbedding or computeSimilarity.
 * @param modelDir - Path to directory containing the ONNX model file
 * @returns true if initialization succeeded
 */
export const initModel: (modelDir: string) => boolean;

/**
 * Extract a 192-dimensional speaker embedding from PCM audio.
 * @param pcmData - Float32Array of PCM samples normalized to [-1, 1]
 * @param sampleRate - Sample rate in Hz (expected: 16000)
 * @returns Float32Array of 192 floats, or throws on failure
 */
export const extractEmbedding: (pcmData: Float32Array, sampleRate: number) => Float32Array;

/**
 * Compute cosine similarity between two speaker embeddings.
 * @param embedding1 - First 192-dim Float32Array embedding
 * @param embedding2 - Second 192-dim Float32Array embedding
 * @returns Cosine similarity in range [-1, 1]
 */
export const computeSimilarity: (embedding1: Float32Array, embedding2: Float32Array) => number;

/**
 * Get the embedding dimension (192 for 3D-Speaker model).
 * @returns Embedding dimension
 */
export const getEmbeddingDim: () => number;

/**
 * Check if the model has been loaded.
 * @returns true if initModel() has been called successfully
 */
export const isModelLoaded: () => boolean;

// ===== Speaker Management (Manager API) =====

export interface SpeakerMatch {
  name: string;
  score: number;
}

/**
 * Register a speaker with one or more embedding vectors.
 * Manager internally averages multiple embeddings.
 * @param name - Speaker name
 * @param embeddings - Array of 192-dim Float32Array embeddings
 * @returns true if registration succeeded
 */
export const registerSpeaker: (name: string, embeddings: Float32Array[]) => boolean;

/**
 * Remove a registered speaker.
 * @param name - Speaker name to remove
 * @returns true if removal succeeded
 */
export const removeSpeaker: (name: string) => boolean;

/**
 * Get all registered speaker names.
 * @returns Array of speaker names
 */
export const getAllSpeakers: () => string[];

/**
 * Get the number of registered speakers.
 * @returns Number of speakers
 */
export const getNumSpeakers: () => number;

/**
 * Check if a speaker is registered.
 * @param name - Speaker name
 * @returns true if speaker exists
 */
export const containsSpeaker: (name: string) => boolean;

/**
 * Identify the best matching speaker for an embedding.
 * @param embedding - 192-dim Float32Array embedding
 * @param threshold - Minimum similarity threshold
 * @returns SpeakerMatch with name and score, or { name: "", score: 0 } if no match
 */
export const identifySpeaker: (embedding: Float32Array, threshold: number) => SpeakerMatch;

/**
 * Get top-N best matching speakers.
 * @param embedding - 192-dim Float32Array embedding
 * @param threshold - Minimum similarity threshold
 * @param topN - Maximum number of results
 * @returns Array of SpeakerMatch sorted by score descending
 */
export const getBestMatches: (embedding: Float32Array, threshold: number, topN: number) => SpeakerMatch[];

/**
 * Verify if an embedding matches a specific speaker.
 * @param name - Speaker name to verify against
 * @param embedding - 192-dim Float32Array embedding
 * @param threshold - Minimum similarity threshold
 * @returns true if the embedding matches the speaker above threshold
 */
export const verifySpeaker: (name: string, embedding: Float32Array, threshold: number) => boolean;

/**
 * Export a speaker's stored embedding (for persistence).
 * @param name - Speaker name
 * @returns Float32Array embedding or null if speaker not found
 */
export const exportSpeakerEmbedding: (name: string) => Float32Array | null;

/**
 * Import a speaker embedding (for restoring from persistence).
 * @param name - Speaker name
 * @param embedding - 192-dim Float32Array embedding
 * @returns true if import succeeded
 */
export const importSpeakerEmbedding: (name: string, embedding: Float32Array) => boolean;
