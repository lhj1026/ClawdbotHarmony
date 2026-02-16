/**
 * Voice mood/emotion detector for Talk Mode.
 * Analyzes PCM audio features (energy, pitch proxy, speaking rate)
 * combined with text sentiment keywords to detect user mood.
 *
 * Input: raw PCM buffers (16kHz, 16-bit, mono) + ASR recognized text
 * Output: mood category with emoji, label, and confidence
 */

export interface MoodResult {
  mood: string;       // 'happy' | 'excited' | 'calm' | 'sad' | 'angry' | 'tired' | 'humming' | 'neutral'
  emoji: string;
  confidence: number; // 0.0 - 1.0
  label: string;      // Chinese display label
}

interface AudioFeatures {
  avgRms: number;
  rmsVariance: number;
  avgZcr: number;
  zcrVariance: number;
  durationSec: number;
}

// Mood definitions
const MOODS: Record<string, MoodResult> = {
  'happy':   { mood: 'happy',   emoji: '\uD83D\uDE0A', confidence: 0, label: '开心' },
  'excited': { mood: 'excited', emoji: '\uD83E\uDD29', confidence: 0, label: '兴奋' },
  'calm':    { mood: 'calm',    emoji: '\uD83D\uDE0C', confidence: 0, label: '平和' },
  'sad':     { mood: 'sad',     emoji: '\uD83D\uDE22', confidence: 0, label: '难过' },
  'angry':   { mood: 'angry',   emoji: '\uD83D\uDE20', confidence: 0, label: '生气' },
  'tired':   { mood: 'tired',   emoji: '\uD83D\uDE34', confidence: 0, label: '疲惫' },
  'humming': { mood: 'humming', emoji: '\uD83C\uDFB5', confidence: 0, label: '哼歌' },
  'neutral': { mood: 'neutral', emoji: '\uD83D\uDE10', confidence: 0, label: '平静' },
};

// Text sentiment keywords
const POSITIVE_WORDS: string[] = [
  '开心', '高兴', '太好了', '哈哈', '棒', '厉害', '好棒', '不错', '真好', '太棒',
  '爽', '喜欢', '爱', '感谢', '谢谢', '耶', '哇', '好的', '好呀', '嘻嘻',
  'great', 'happy', 'awesome', 'love', 'haha', 'nice', 'good', 'wonderful', 'amazing', 'yay',
];

const NEGATIVE_WORDS: string[] = [
  '难过', '伤心', '烦', '累', '生气', '讨厌', '无聊', '郁闷', '烦躁', '气死',
  '不开心', '不高兴', '难受', '痛苦', '失望', '焦虑', '压力', '崩溃', '受不了',
  'sad', 'angry', 'tired', 'hate', 'annoyed', 'upset', 'frustrated', 'depressed', 'bored', 'stressed',
];

// Frame size for analysis (512 samples = 32ms at 16kHz)
const FRAME_SIZE = 512;
const SAMPLE_RATE = 16000;

/**
 * Detect user mood from voice audio and recognized text.
 *
 * @param pcmBuffers  Raw PCM buffers from AudioCapturer (16kHz, 16-bit, mono)
 * @param recognizedText  ASR result text
 * @returns MoodResult with mood, emoji, confidence, and label
 */
export function detectMood(pcmBuffers: ArrayBuffer[], recognizedText: string): MoodResult {
  if (pcmBuffers.length === 0) {
    return makeMood('neutral', 0.5);
  }

  // Extract audio features
  let features = extractAudioFeatures(pcmBuffers);

  // Analyze text sentiment
  let textLower = recognizedText.toLowerCase();
  let positiveScore = countMatches(textLower, POSITIVE_WORDS);
  let negativeScore = countMatches(textLower, NEGATIVE_WORDS);

  // Compute speech rate (characters per second)
  let speechRate = features.durationSec > 0 ? recognizedText.length / features.durationSec : 0;

  // --- Decision tree ---

  // 1. Humming: sustained energy + low ZCR variance + no/little text
  if (recognizedText.length < 3 && features.avgRms > 500 && features.zcrVariance < 0.01) {
    return makeMood('humming', 0.8);
  }

  // 2. Excited: very high energy + fast speech
  if (features.avgRms > 3500 && speechRate > 5) {
    let conf = Math.min(1.0, 0.6 + positiveScore * 0.1);
    return makeMood('excited', conf);
  }

  // 3. Angry: high energy + high energy variance + negative words
  if (features.avgRms > 3000 && features.rmsVariance > 2000000 && negativeScore > 0) {
    let conf = Math.min(1.0, 0.5 + negativeScore * 0.15);
    return makeMood('angry', conf);
  }

  // 4. Happy: high energy + positive words
  if (features.avgRms > 2500 && positiveScore > 0) {
    let conf = Math.min(1.0, 0.5 + positiveScore * 0.15);
    return makeMood('happy', conf);
  }

  // 5. Tired: very low energy + slow speech
  if (features.avgRms < 800 && speechRate > 0 && speechRate < 2) {
    return makeMood('tired', 0.6);
  }

  // 6. Sad: low energy + negative words
  if (features.avgRms < 1200 && negativeScore > 0) {
    let conf = Math.min(1.0, 0.5 + negativeScore * 0.15);
    return makeMood('sad', conf);
  }

  // 7. Text-only sentiment (when audio is ambiguous)
  if (positiveScore >= 2 && negativeScore === 0) {
    return makeMood('happy', 0.5);
  }
  if (negativeScore >= 2 && positiveScore === 0) {
    return makeMood('sad', 0.5);
  }

  // 8. Calm: low energy variance + moderate energy
  if (features.rmsVariance < 500000 && features.avgRms >= 800 && features.avgRms <= 2500) {
    return makeMood('calm', 0.4);
  }

  // 9. Fallback
  return makeMood('neutral', 0.3);
}

function makeMood(mood: string, confidence: number): MoodResult {
  let template = MOODS[mood];
  if (!template) {
    return { mood: 'neutral', emoji: '\uD83D\uDE10', confidence: 0.3, label: '平静' };
  }
  return {
    mood: template.mood,
    emoji: template.emoji,
    confidence: confidence,
    label: template.label,
  };
}

function countMatches(text: string, keywords: string[]): number {
  let count = 0;
  for (let kw of keywords) {
    if (text.includes(kw)) {
      count++;
    }
  }
  return count;
}

/**
 * Extract audio features from PCM buffers.
 * Splits into 512-sample frames and computes RMS + ZCR per frame.
 */
function extractAudioFeatures(pcmBuffers: ArrayBuffer[]): AudioFeatures {
  let frameRms: number[] = [];
  let frameZcr: number[] = [];
  let totalSamples = 0;

  for (let buf of pcmBuffers) {
    let samples = new Int16Array(buf);
    totalSamples += samples.length;

    // Process in frames
    let frameCount = Math.floor(samples.length / FRAME_SIZE);
    for (let f = 0; f < frameCount; f++) {
      let offset = f * FRAME_SIZE;

      // RMS energy
      let sumSq = 0;
      for (let i = 0; i < FRAME_SIZE; i++) {
        let s = samples[offset + i];
        sumSq += s * s;
      }
      let rms = Math.sqrt(sumSq / FRAME_SIZE);
      frameRms.push(rms);

      // Zero-crossing rate
      let crossings = 0;
      for (let i = 1; i < FRAME_SIZE; i++) {
        if ((samples[offset + i] >= 0) !== (samples[offset + i - 1] >= 0)) {
          crossings++;
        }
      }
      let zcr = crossings / FRAME_SIZE;
      frameZcr.push(zcr);
    }
  }

  if (frameRms.length === 0) {
    return { avgRms: 0, rmsVariance: 0, avgZcr: 0, zcrVariance: 0, durationSec: 0 };
  }

  // Compute mean + variance
  let avgRms = mean(frameRms);
  let rmsVariance = variance(frameRms, avgRms);
  let avgZcr = mean(frameZcr);
  let zcrVariance = variance(frameZcr, avgZcr);
  let durationSec = totalSamples / SAMPLE_RATE;

  return { avgRms, rmsVariance, avgZcr, zcrVariance, durationSec };
}

function mean(values: number[]): number {
  let sum = 0;
  for (let v of values) {
    sum += v;
  }
  return sum / values.length;
}

function variance(values: number[], avg: number): number {
  let sumSq = 0;
  for (let v of values) {
    let diff = v - avg;
    sumSq += diff * diff;
  }
  return sumSq / values.length;
}
