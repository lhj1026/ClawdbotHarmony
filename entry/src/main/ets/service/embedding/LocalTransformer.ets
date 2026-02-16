import { common } from '@kit.AbilityKit';
import { LogService } from '../../common/LogService';

interface ModelConfig {
  hidden_size: number;
  num_hidden_layers: number;
  num_attention_heads: number;
  intermediate_size: number;
  max_position_embeddings: number;
  vocab_size: number;
  embedding_dim: number;
}

interface TransformerLayer {
  qWeight: Float32Array;
  qBias: Float32Array;
  kWeight: Float32Array;
  kBias: Float32Array;
  vWeight: Float32Array;
  vBias: Float32Array;
  oWeight: Float32Array;
  oBias: Float32Array;
  ln1Weight: Float32Array;
  ln1Bias: Float32Array;
  intWeight: Float32Array;
  intBias: Float32Array;
  outWeight: Float32Array;
  outBias: Float32Array;
  ln2Weight: Float32Array;
  ln2Bias: Float32Array;
}

interface BinTensor {
  name: string;
  shape: number[];
  data: Float32Array;
}

const MAGIC = 0x454D4231;
const SQRT_2_OVER_PI = 0.7978845608028654; // sqrt(2/pi)

/** Convert Uint8Array to string without spread operator (avoids stack overflow on large arrays) */
function uint8ArrayToString(arr: Uint8Array): string {
  let result = '';
  for (let i = 0; i < arr.length; i++) {
    result += String.fromCharCode(arr[i]);
  }
  return result;
}

export class LocalTransformer {
  private config: ModelConfig = {
    hidden_size: 384, num_hidden_layers: 6, num_attention_heads: 12,
    intermediate_size: 1536, max_position_embeddings: 512,
    vocab_size: 30522, embedding_dim: 384
  };
  private wordEmbRaw: Uint8Array = new Uint8Array(0);
  private posEmb: Float32Array = new Float32Array(0);
  private typeEmb: Float32Array = new Float32Array(0);
  private embLnW: Float32Array = new Float32Array(0);
  private embLnB: Float32Array = new Float32Array(0);
  private layers: TransformerLayer[] = [];
  private loaded: boolean = false;
  private log: LogService = LogService.getInstance();
  private readonly TAG = 'LocalTransformer';

  async load(context: common.Context): Promise<void> {
    let rm = (context as common.UIAbilityContext).resourceManager;
    let t0 = Date.now();

    // Load config (async to avoid blocking main thread)
    let cfgRaw = await rm.getRawFileContent('model/config.json');
    let cfgStr = uint8ArrayToString(cfgRaw);
    this.config = JSON.parse(cfgStr) as ModelConfig;
    this.log.info(this.TAG, `Config: h=${this.config.hidden_size} layers=${this.config.num_hidden_layers} heads=${this.config.num_attention_heads}`);

    // Yield to event loop after config load
    await this.yieldToEventLoop();

    // Load embeddings (async) — use slice() to get a properly-sized copy,
    // because getRawFileContent may return a view into a larger shared buffer
    let embRaw = await rm.getRawFileContent('model/embeddings.bin');
    let embData = embRaw.slice();
    let tensors = this.parseBin(embData);
    let tMap = new Map<string, Float32Array>();
    for (let t of tensors) {
      tMap.set(t.name, t.data);
    }

    // Word embeddings: keep as raw Uint8Array for on-demand lookup
    this.wordEmbRaw = this.extractRawTensor(embData, 'word_embeddings.weight');
    this.posEmb = tMap.get('position_embeddings.weight') ?? new Float32Array(0);
    this.typeEmb = tMap.get('token_type_embeddings.weight') ?? new Float32Array(0);
    this.embLnW = tMap.get('LayerNorm.weight') ?? new Float32Array(0);
    this.embLnB = tMap.get('LayerNorm.bias') ?? new Float32Array(0);

    // Yield to event loop after embeddings
    await this.yieldToEventLoop();

    // Load transformer layers (async with yield between each layer to avoid ANR)
    this.layers = [];
    for (let i = 0; i < this.config.num_hidden_layers; i++) {
      let layerRaw = await rm.getRawFileContent(`model/layer_${i.toString().padStart(2, '0')}.bin`);
      let lt = this.parseBin(layerRaw.slice());
      let lm = new Map<string, Float32Array>();
      for (let t of lt) {
        lm.set(t.name, t.data);
      }

      let layer: TransformerLayer = {
        qWeight: lm.get('attention.self.query.weight') ?? new Float32Array(0),
        qBias: lm.get('attention.self.query.bias') ?? new Float32Array(0),
        kWeight: lm.get('attention.self.key.weight') ?? new Float32Array(0),
        kBias: lm.get('attention.self.key.bias') ?? new Float32Array(0),
        vWeight: lm.get('attention.self.value.weight') ?? new Float32Array(0),
        vBias: lm.get('attention.self.value.bias') ?? new Float32Array(0),
        oWeight: lm.get('attention.output.dense.weight') ?? new Float32Array(0),
        oBias: lm.get('attention.output.dense.bias') ?? new Float32Array(0),
        ln1Weight: lm.get('attention.output.LayerNorm.weight') ?? new Float32Array(0),
        ln1Bias: lm.get('attention.output.LayerNorm.bias') ?? new Float32Array(0),
        intWeight: lm.get('intermediate.dense.weight') ?? new Float32Array(0),
        intBias: lm.get('intermediate.dense.bias') ?? new Float32Array(0),
        outWeight: lm.get('output.dense.weight') ?? new Float32Array(0),
        outBias: lm.get('output.dense.bias') ?? new Float32Array(0),
        ln2Weight: lm.get('output.LayerNorm.weight') ?? new Float32Array(0),
        ln2Bias: lm.get('output.LayerNorm.bias') ?? new Float32Array(0),
      };
      this.layers.push(layer);
      // Yield to event loop after each layer to avoid ANR
      await this.yieldToEventLoop();
    }

    this.loaded = true;
    this.log.info(this.TAG, `Model loaded in ${Date.now() - t0}ms`);
  }

  private yieldToEventLoop(): Promise<void> {
    return new Promise<void>((resolve): void => {
      setTimeout((): void => resolve(), 0);
    });
  }

  forward(inputIds: Int32Array, attentionMask: Int32Array, tokenTypeIds: Int32Array): Float32Array {
    let h = this.config.hidden_size;
    let seqLen = inputIds.length;

    // 1. Embedding lookup
    let hidden = new Float32Array(seqLen * h);
    for (let s = 0; s < seqLen; s++) {
      let wordRow = this.lookupWordEmb(inputIds[s]);
      let posOff = s * h;
      let typeOff = tokenTypeIds[s] * h;
      let outOff = s * h;
      for (let d = 0; d < h; d++) {
        hidden[outOff + d] = wordRow[d] + this.posEmb[posOff + d] + this.typeEmb[typeOff + d];
      }
    }

    // Embedding LayerNorm
    this.layerNormBatch(hidden, this.embLnW, this.embLnB, seqLen, h);

    // 2. Transformer layers
    let numHeads = this.config.num_attention_heads;
    let headDim = h / numHeads;
    let scale = 1.0 / Math.sqrt(headDim);

    for (let li = 0; li < this.layers.length; li++) {
      let layer = this.layers[li];

      // Self-attention: Q, K, V projections
      let Q = this.linearBatch(hidden, layer.qWeight, layer.qBias, seqLen, h, h);
      let K = this.linearBatch(hidden, layer.kWeight, layer.kBias, seqLen, h, h);
      let V = this.linearBatch(hidden, layer.vWeight, layer.vBias, seqLen, h, h);

      // Multi-head attention
      let attnOut = new Float32Array(seqLen * h);
      for (let head = 0; head < numHeads; head++) {
        let hOff = head * headDim;

        // Compute attention scores for this head
        let scores = new Float32Array(seqLen * seqLen);
        for (let i = 0; i < seqLen; i++) {
          for (let j = 0; j < seqLen; j++) {
            let dot = 0;
            let qi = i * h + hOff;
            let kj = j * h + hOff;
            for (let d = 0; d < headDim; d++) {
              dot += Q[qi + d] * K[kj + d];
            }
            scores[i * seqLen + j] = dot * scale;
          }
        }

        // Apply attention mask
        for (let i = 0; i < seqLen; i++) {
          for (let j = 0; j < seqLen; j++) {
            if (attentionMask[j] === 0) {
              scores[i * seqLen + j] = -10000.0;
            }
          }
        }

        // Softmax per row
        for (let i = 0; i < seqLen; i++) {
          this.softmax(scores, i * seqLen, seqLen);
        }

        // Weighted sum of values
        for (let i = 0; i < seqLen; i++) {
          for (let d = 0; d < headDim; d++) {
            let sum = 0;
            for (let j = 0; j < seqLen; j++) {
              sum += scores[i * seqLen + j] * V[j * h + hOff + d];
            }
            attnOut[i * h + hOff + d] = sum;
          }
        }
      }

      // Output projection + residual + LayerNorm
      let attnProj = this.linearBatch(attnOut, layer.oWeight, layer.oBias, seqLen, h, h);
      for (let i = 0; i < seqLen * h; i++) {
        hidden[i] += attnProj[i];
      }
      this.layerNormBatch(hidden, layer.ln1Weight, layer.ln1Bias, seqLen, h);

      // FFN: intermediate (GELU) + output + residual + LayerNorm
      let inter = this.config.intermediate_size;
      let ffnUp = this.linearBatch(hidden, layer.intWeight, layer.intBias, seqLen, h, inter);
      // Apply GELU
      for (let i = 0; i < seqLen * inter; i++) {
        ffnUp[i] = this.gelu(ffnUp[i]);
      }
      let ffnDown = this.linearBatch(ffnUp, layer.outWeight, layer.outBias, seqLen, inter, h);
      for (let i = 0; i < seqLen * h; i++) {
        hidden[i] += ffnDown[i];
      }
      this.layerNormBatch(hidden, layer.ln2Weight, layer.ln2Bias, seqLen, h);
    }

    // 3. Mean pooling (attention mask weighted)
    let pooled = new Float32Array(h);
    let maskSum = 0;
    for (let s = 0; s < seqLen; s++) {
      maskSum += attentionMask[s];
    }
    if (maskSum === 0) maskSum = 1;

    for (let d = 0; d < h; d++) {
      let sum = 0;
      for (let s = 0; s < seqLen; s++) {
        sum += hidden[s * h + d] * attentionMask[s];
      }
      pooled[d] = sum / maskSum;
    }

    // 4. L2 normalize
    let norm = 0;
    for (let d = 0; d < h; d++) {
      norm += pooled[d] * pooled[d];
    }
    norm = Math.sqrt(norm);
    if (norm > 0) {
      for (let d = 0; d < h; d++) {
        pooled[d] /= norm;
      }
    }

    return pooled;
  }

  getDimension(): number {
    return this.config.embedding_dim;
  }

  /**
   * Async forward pass with yields between layers to prevent UI blocking.
   */
  async forwardAsync(inputIds: Int32Array, attentionMask: Int32Array, tokenTypeIds: Int32Array): Promise<Float32Array> {
    let h = this.config.hidden_size;
    let seqLen = inputIds.length;

    // 1. Embedding lookup
    let hidden = new Float32Array(seqLen * h);
    for (let s = 0; s < seqLen; s++) {
      let wordRow = this.lookupWordEmb(inputIds[s]);
      let posOff = s * h;
      let typeOff = tokenTypeIds[s] * h;
      let outOff = s * h;
      for (let d = 0; d < h; d++) {
        hidden[outOff + d] = wordRow[d] + this.posEmb[posOff + d] + this.typeEmb[typeOff + d];
      }
    }

    // Embedding LayerNorm
    this.layerNormBatch(hidden, this.embLnW, this.embLnB, seqLen, h);

    // Yield after embedding
    await this.yieldToEventLoop();

    // 2. Transformer layers with yield between each layer
    let numHeads = this.config.num_attention_heads;
    let headDim = h / numHeads;
    let scale = 1.0 / Math.sqrt(headDim);

    for (let li = 0; li < this.layers.length; li++) {
      let layer = this.layers[li];

      // Self-attention: Q, K, V projections
      let Q = this.linearBatch(hidden, layer.qWeight, layer.qBias, seqLen, h, h);
      let K = this.linearBatch(hidden, layer.kWeight, layer.kBias, seqLen, h, h);
      let V = this.linearBatch(hidden, layer.vWeight, layer.vBias, seqLen, h, h);

      // Multi-head attention
      let attnOut = new Float32Array(seqLen * h);
      for (let head = 0; head < numHeads; head++) {
        let hOff = head * headDim;

        let scores = new Float32Array(seqLen * seqLen);
        for (let i = 0; i < seqLen; i++) {
          for (let j = 0; j < seqLen; j++) {
            let dot = 0;
            let qi = i * h + hOff;
            let kj = j * h + hOff;
            for (let d = 0; d < headDim; d++) {
              dot += Q[qi + d] * K[kj + d];
            }
            scores[i * seqLen + j] = dot * scale;
          }
        }

        for (let i = 0; i < seqLen; i++) {
          for (let j = 0; j < seqLen; j++) {
            if (attentionMask[j] === 0) {
              scores[i * seqLen + j] = -10000.0;
            }
          }
        }

        for (let i = 0; i < seqLen; i++) {
          this.softmax(scores, i * seqLen, seqLen);
        }

        for (let i = 0; i < seqLen; i++) {
          for (let d = 0; d < headDim; d++) {
            let sum = 0;
            for (let j = 0; j < seqLen; j++) {
              sum += scores[i * seqLen + j] * V[j * h + hOff + d];
            }
            attnOut[i * h + hOff + d] = sum;
          }
        }
      }

      let attnProj = this.linearBatch(attnOut, layer.oWeight, layer.oBias, seqLen, h, h);
      for (let i = 0; i < seqLen * h; i++) {
        hidden[i] += attnProj[i];
      }
      this.layerNormBatch(hidden, layer.ln1Weight, layer.ln1Bias, seqLen, h);

      let inter = this.config.intermediate_size;
      let ffnUp = this.linearBatch(hidden, layer.intWeight, layer.intBias, seqLen, h, inter);
      for (let i = 0; i < seqLen * inter; i++) {
        ffnUp[i] = this.gelu(ffnUp[i]);
      }
      let ffnDown = this.linearBatch(ffnUp, layer.outWeight, layer.outBias, seqLen, inter, h);
      for (let i = 0; i < seqLen * h; i++) {
        hidden[i] += ffnDown[i];
      }
      this.layerNormBatch(hidden, layer.ln2Weight, layer.ln2Bias, seqLen, h);

      // Yield after each layer to let UI respond
      await this.yieldToEventLoop();
    }

    // 3. Mean pooling
    let pooled = new Float32Array(h);
    let maskSum = 0;
    for (let s = 0; s < seqLen; s++) {
      maskSum += attentionMask[s];
    }
    if (maskSum === 0) maskSum = 1;

    for (let d = 0; d < h; d++) {
      let sum = 0;
      for (let s = 0; s < seqLen; s++) {
        sum += hidden[s * h + d] * attentionMask[s];
      }
      pooled[d] = sum / maskSum;
    }

    // 4. L2 normalize
    let norm = 0;
    for (let d = 0; d < h; d++) {
      norm += pooled[d] * pooled[d];
    }
    norm = Math.sqrt(norm);
    if (norm > 0) {
      for (let d = 0; d < h; d++) {
        pooled[d] /= norm;
      }
    }

    return pooled;
  }

  // ---- Private helpers ----

  private lookupWordEmb(tokenId: number): Float32Array {
    let h = this.config.hidden_size;
    let offset = tokenId * h * 2; // 2 bytes per float16
    let end = offset + h * 2;
    if (end > this.wordEmbRaw.length) {
      return new Float32Array(h);
    }
    return this.f16ToF32(this.wordEmbRaw, offset, h);
  }

  // Linear transform: output[seq][outDim] = input[seq][inDim] * weight^T[outDim][inDim] + bias[outDim]
  // PyTorch stores Linear weights as [outDim, inDim]
  private linearBatch(input: Float32Array, weight: Float32Array, bias: Float32Array,
    seqLen: number, inDim: number, outDim: number): Float32Array {
    let output = new Float32Array(seqLen * outDim);
    for (let s = 0; s < seqLen; s++) {
      let inOff = s * inDim;
      let outOff = s * outDim;
      for (let o = 0; o < outDim; o++) {
        let sum = bias[o];
        let wOff = o * inDim;
        for (let i = 0; i < inDim; i++) {
          sum += input[inOff + i] * weight[wOff + i];
        }
        output[outOff + o] = sum;
      }
    }
    return output;
  }

  private layerNormBatch(data: Float32Array, weight: Float32Array, bias: Float32Array,
    seqLen: number, h: number): void {
    let eps = 1e-12;
    for (let s = 0; s < seqLen; s++) {
      let off = s * h;
      // Compute mean
      let mean = 0;
      for (let d = 0; d < h; d++) {
        mean += data[off + d];
      }
      mean /= h;
      // Compute variance
      let variance = 0;
      for (let d = 0; d < h; d++) {
        let diff = data[off + d] - mean;
        variance += diff * diff;
      }
      variance /= h;
      let stdInv = 1.0 / Math.sqrt(variance + eps);
      // Normalize
      for (let d = 0; d < h; d++) {
        data[off + d] = (data[off + d] - mean) * stdInv * weight[d] + bias[d];
      }
    }
  }

  private softmax(arr: Float32Array, offset: number, len: number): void {
    let max = -Infinity;
    for (let i = 0; i < len; i++) {
      if (arr[offset + i] > max) max = arr[offset + i];
    }
    let sum = 0;
    for (let i = 0; i < len; i++) {
      arr[offset + i] = Math.exp(arr[offset + i] - max);
      sum += arr[offset + i];
    }
    for (let i = 0; i < len; i++) {
      arr[offset + i] /= sum;
    }
  }

  private gelu(x: number): number {
    return 0.5 * x * (1.0 + Math.tanh(SQRT_2_OVER_PI * (x + 0.044715 * x * x * x)));
  }

  // Parse binary weight file format
  private parseBin(raw: Uint8Array): BinTensor[] {
    let view = new DataView(raw.buffer, raw.byteOffset, raw.byteLength);
    let pos = 0;

    let magic = view.getUint32(pos, true); pos += 4;
    if (magic !== MAGIC) {
      throw new Error(`Invalid magic: 0x${magic.toString(16)}`);
    }

    let tensorCount = view.getUint32(pos, true); pos += 4;

    // Parse headers
    interface TensorHeader {
      name: string;
      shape: number[];
      dataLen: number;
    }
    let headers: TensorHeader[] = [];
    for (let t = 0; t < tensorCount; t++) {
      let nameLen = view.getUint32(pos, true); pos += 4;
      let nameBytes = raw.subarray(pos, pos + nameLen);
      let name = String.fromCharCode(...nameBytes);
      pos += nameLen;

      let ndim = view.getUint32(pos, true); pos += 4;
      let shape: number[] = [];
      for (let d = 0; d < ndim; d++) {
        shape.push(view.getUint32(pos, true));
        pos += 4;
      }

      let dataLen = view.getUint32(pos, true); pos += 4;
      headers.push({ name, shape, dataLen });
    }

    // Parse data
    let tensors: BinTensor[] = [];
    let dataStart = pos;
    for (let header of headers) {
      let numElements = header.dataLen / 2; // float16 = 2 bytes
      let f32 = this.f16ToF32(raw, dataStart, numElements);
      tensors.push({ name: header.name, shape: header.shape, data: f32 });
      dataStart += header.dataLen;
    }

    return tensors;
  }

  // Extract raw float16 bytes for a named tensor (for word embeddings)
  private extractRawTensor(raw: Uint8Array, targetName: string): Uint8Array {
    let view = new DataView(raw.buffer, raw.byteOffset, raw.byteLength);
    let pos = 0;

    let magic = view.getUint32(pos, true); pos += 4;
    if (magic !== MAGIC) return new Uint8Array(0);

    let tensorCount = view.getUint32(pos, true); pos += 4;

    interface THeader { name: string; dataLen: number; }
    let headers: THeader[] = [];
    for (let t = 0; t < tensorCount; t++) {
      let nameLen = view.getUint32(pos, true); pos += 4;
      let nameBytes = raw.subarray(pos, pos + nameLen);
      let name = String.fromCharCode(...nameBytes);
      pos += nameLen;
      let ndim = view.getUint32(pos, true); pos += 4;
      pos += ndim * 4; // skip shape
      let dataLen = view.getUint32(pos, true); pos += 4;
      headers.push({ name, dataLen });
    }

    let dataStart = pos;
    for (let header of headers) {
      if (header.name === targetName) {
        return raw.slice(dataStart, dataStart + header.dataLen);
      }
      dataStart += header.dataLen;
    }
    return new Uint8Array(0);
  }

  // Convert float16 to float32
  private f16ToF32(raw: Uint8Array, byteOffset: number, count: number): Float32Array {
    let result = new Float32Array(count);
    let view = new DataView(raw.buffer, raw.byteOffset + byteOffset, count * 2);
    for (let i = 0; i < count; i++) {
      let h = view.getUint16(i * 2, true);
      let sign = (h >> 15) & 1;
      let exp = (h >> 10) & 0x1F;
      let mant = h & 0x3FF;

      let val: number;
      if (exp === 0) {
        val = (mant / 1024) * Math.pow(2, -14);
      } else if (exp === 31) {
        val = mant === 0 ? Infinity : NaN;
      } else {
        val = (1 + mant / 1024) * Math.pow(2, exp - 15);
      }
      result[i] = sign ? -val : val;
    }
    return result;
  }
}
