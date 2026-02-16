/**
 * Native module for speaker embedding extraction using sherpa-onnx.
 * Provides voiceprint (speaker identification) capabilities via NAPI.
 *
 * Dependencies: sherpa-onnx with ONNX Runtime
 * Model: 3D-Speaker (192-dim embeddings)
 */
#include <cmath>
#include <cstring>
#include <string>
#include <vector>
#include <map>
#include <napi/native_api.h>

// TODO: Include sherpa-onnx headers when library is integrated
// #include "sherpa-onnx/c-api/c-api.h"

// Embedding dimension for 3D-Speaker model
static constexpr int EMBEDDING_DIM = 192;

// Whether the model has been initialized
static bool g_initialized = false;

// TODO: sherpa-onnx speaker embedding extractor handle
// static const SherpaOnnxSpeakerEmbeddingExtractor *g_extractor = nullptr;
// static const SherpaOnnxSpeakerEmbeddingManager *g_manager = nullptr;

// In-memory speaker store (stub for Manager until sherpa-onnx is linked)
static std::map<std::string, std::vector<float>> g_speakers;

// ===== Helper: get string from napi_value =====
static std::string NapiGetString(napi_env env, napi_value value) {
    size_t len = 0;
    napi_get_value_string_utf8(env, value, nullptr, 0, &len);
    std::string str(len, '\0');
    napi_get_value_string_utf8(env, value, &str[0], len + 1, &len);
    return str;
}

// ===== Helper: get float array from Float32Array =====
static bool NapiGetFloat32Array(napi_env env, napi_value value, float **data, size_t *length) {
    bool isTypedArray = false;
    napi_is_typedarray(env, value, &isTypedArray);
    if (!isTypedArray) return false;

    napi_typedarray_type type;
    napi_value arrayBuffer;
    size_t byteOffset;
    napi_get_typedarray_info(env, value, &type, length, (void **)data, &arrayBuffer, &byteOffset);
    return type == napi_float32_array;
}

// ===== Helper: create Float32Array result =====
static napi_value NapiCreateFloat32Array(napi_env env, const float *data, size_t length) {
    napi_value outputBuffer;
    void *outputData = nullptr;
    napi_create_arraybuffer(env, length * sizeof(float), &outputData, &outputBuffer);
    memcpy(outputData, data, length * sizeof(float));

    napi_value resultArray;
    napi_create_typedarray(env, napi_float32_array, length, outputBuffer, 0, &resultArray);
    return resultArray;
}

// ===== Helper: cosine similarity =====
static double CosineSimilarity(const float *a, const float *b, int dim) {
    double dot = 0.0, normA = 0.0, normB = 0.0;
    for (int i = 0; i < dim; i++) {
        dot += a[i] * b[i];
        normA += a[i] * a[i];
        normB += b[i] * b[i];
    }
    if (normA > 0 && normB > 0) {
        return dot / (std::sqrt(normA) * std::sqrt(normB));
    }
    return 0.0;
}

/**
 * initModel(modelDir: string): boolean
 */
static napi_value InitModel(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 1) {
        napi_throw_error(env, nullptr, "initModel requires modelDir string");
        return nullptr;
    }

    std::string modelDir = NapiGetString(env, args[0]);

    // TODO: Initialize sherpa-onnx speaker embedding extractor
    // SherpaOnnxSpeakerEmbeddingExtractorConfig config;
    // memset(&config, 0, sizeof(config));
    // config.model = (modelDir + "/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx").c_str();
    // config.num_threads = 2;
    // config.provider = "cpu";
    // g_extractor = SherpaOnnxCreateSpeakerEmbeddingExtractor(&config);
    // int dim = SherpaOnnxSpeakerEmbeddingExtractorDim(g_extractor);
    // g_manager = SherpaOnnxCreateSpeakerEmbeddingManager(dim);

    g_initialized = true; // Stub: always succeed for now

    napi_value result;
    napi_get_boolean(env, g_initialized, &result);
    return result;
}

/**
 * extractEmbedding(pcmData: Float32Array, sampleRate: number): Float32Array | null
 */
static napi_value ExtractEmbedding(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 2) {
        napi_throw_error(env, nullptr, "extractEmbedding requires (pcmData: Float32Array, sampleRate: number)");
        return nullptr;
    }

    if (!g_initialized) {
        napi_throw_error(env, nullptr, "Model not initialized. Call initModel() first.");
        return nullptr;
    }

    float *pcmSamples = nullptr;
    size_t length = 0;
    if (!NapiGetFloat32Array(env, args[0], &pcmSamples, &length)) {
        napi_throw_error(env, nullptr, "pcmData must be a Float32Array");
        return nullptr;
    }

    int32_t sampleRate = 16000;
    napi_get_value_int32(env, args[1], &sampleRate);

    // TODO: Use sherpa-onnx to extract embedding
    // SherpaOnnxOnlineStream *stream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(g_extractor);
    // SherpaOnnxOnlineStreamAcceptWaveform(stream, sampleRate, pcmSamples, length);
    // SherpaOnnxOnlineStreamInputFinished(stream);
    // if (!SherpaOnnxSpeakerEmbeddingExtractorIsReady(g_extractor, stream)) { ... }
    // const float *embedding = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(g_extractor, stream);

    // Stub: return deterministic pseudo-embedding based on audio energy
    std::vector<float> embedding(EMBEDDING_DIM, 0.0f);
    if (length > 0) {
        double energy = 0.0;
        for (size_t i = 0; i < length; i++) {
            energy += pcmSamples[i] * pcmSamples[i];
        }
        energy = std::sqrt(energy / length);
        // Fill with small deterministic values so similarity works
        for (int i = 0; i < EMBEDDING_DIM; i++) {
            embedding[i] = static_cast<float>(std::sin(i * 0.1 + energy * 10.0) * 0.5);
        }
    }

    return NapiCreateFloat32Array(env, embedding.data(), EMBEDDING_DIM);
}

/**
 * computeSimilarity(embedding1: Float32Array, embedding2: Float32Array): number
 */
static napi_value ComputeSimilarity(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 2) {
        napi_throw_error(env, nullptr, "computeSimilarity requires two Float32Array embeddings");
        return nullptr;
    }

    float *emb1 = nullptr, *emb2 = nullptr;
    size_t len1 = 0, len2 = 0;

    if (!NapiGetFloat32Array(env, args[0], &emb1, &len1) ||
        !NapiGetFloat32Array(env, args[1], &emb2, &len2)) {
        napi_throw_error(env, nullptr, "Both embeddings must be Float32Array");
        return nullptr;
    }

    if (len1 != EMBEDDING_DIM || len2 != EMBEDDING_DIM) {
        napi_throw_error(env, nullptr, "Embeddings must have 192 dimensions");
        return nullptr;
    }

    double similarity = CosineSimilarity(emb1, emb2, EMBEDDING_DIM);

    napi_value result;
    napi_create_double(env, similarity, &result);
    return result;
}

/**
 * getEmbeddingDim(): number
 */
static napi_value GetEmbeddingDim(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_create_int32(env, EMBEDDING_DIM, &result);
    return result;
}

/**
 * isModelLoaded(): boolean
 */
static napi_value IsModelLoaded(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_get_boolean(env, g_initialized, &result);
    return result;
}

// ===== Speaker Management Functions =====

/**
 * registerSpeaker(name: string, embeddings: Float32Array[]): boolean
 */
static napi_value RegisterSpeaker(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 2) {
        napi_throw_error(env, nullptr, "registerSpeaker requires (name, embeddings[])");
        return nullptr;
    }

    std::string name = NapiGetString(env, args[0]);

    // Parse embeddings array
    bool isArray = false;
    napi_is_array(env, args[1], &isArray);
    if (!isArray) {
        napi_throw_error(env, nullptr, "embeddings must be an array of Float32Array");
        return nullptr;
    }

    uint32_t arrayLen = 0;
    napi_get_array_length(env, args[1], &arrayLen);

    // Average all embeddings
    std::vector<float> avgEmb(EMBEDDING_DIM, 0.0f);
    uint32_t validCount = 0;

    for (uint32_t i = 0; i < arrayLen; i++) {
        napi_value element;
        napi_get_element(env, args[1], i, &element);

        float *embData = nullptr;
        size_t embLen = 0;
        if (NapiGetFloat32Array(env, element, &embData, &embLen) && embLen == EMBEDDING_DIM) {
            for (int j = 0; j < EMBEDDING_DIM; j++) {
                avgEmb[j] += embData[j];
            }
            validCount++;
        }
    }

    if (validCount == 0) {
        napi_value result;
        napi_get_boolean(env, false, &result);
        return result;
    }

    for (int j = 0; j < EMBEDDING_DIM; j++) {
        avgEmb[j] /= validCount;
    }

    // TODO: Use SherpaOnnxSpeakerEmbeddingManagerAddListFlattened when sherpa-onnx is linked
    g_speakers[name] = avgEmb;

    napi_value result;
    napi_get_boolean(env, true, &result);
    return result;
}

/**
 * removeSpeaker(name: string): boolean
 */
static napi_value RemoveSpeaker(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 1) {
        napi_throw_error(env, nullptr, "removeSpeaker requires name");
        return nullptr;
    }

    std::string name = NapiGetString(env, args[0]);
    bool removed = g_speakers.erase(name) > 0;

    napi_value result;
    napi_get_boolean(env, removed, &result);
    return result;
}

/**
 * getAllSpeakers(): string[]
 */
static napi_value GetAllSpeakers(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_create_array_with_length(env, g_speakers.size(), &result);

    uint32_t idx = 0;
    for (auto &pair : g_speakers) {
        napi_value nameVal;
        napi_create_string_utf8(env, pair.first.c_str(), pair.first.length(), &nameVal);
        napi_set_element(env, result, idx++, nameVal);
    }

    return result;
}

/**
 * getNumSpeakers(): number
 */
static napi_value GetNumSpeakers(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_create_int32(env, static_cast<int32_t>(g_speakers.size()), &result);
    return result;
}

/**
 * containsSpeaker(name: string): boolean
 */
static napi_value ContainsSpeaker(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 1) {
        napi_throw_error(env, nullptr, "containsSpeaker requires name");
        return nullptr;
    }

    std::string name = NapiGetString(env, args[0]);
    bool found = g_speakers.find(name) != g_speakers.end();

    napi_value result;
    napi_get_boolean(env, found, &result);
    return result;
}

/**
 * identifySpeaker(embedding: Float32Array, threshold: number): SpeakerMatch
 */
static napi_value IdentifySpeaker(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 2) {
        napi_throw_error(env, nullptr, "identifySpeaker requires (embedding, threshold)");
        return nullptr;
    }

    float *embData = nullptr;
    size_t embLen = 0;
    if (!NapiGetFloat32Array(env, args[0], &embData, &embLen) || embLen != EMBEDDING_DIM) {
        napi_throw_error(env, nullptr, "embedding must be a Float32Array of 192 dimensions");
        return nullptr;
    }

    double threshold = 0.5;
    napi_get_value_double(env, args[1], &threshold);

    std::string bestName;
    double bestScore = -1.0;

    for (auto &pair : g_speakers) {
        double score = CosineSimilarity(embData, pair.second.data(), EMBEDDING_DIM);
        if (score >= threshold && score > bestScore) {
            bestScore = score;
            bestName = pair.first;
        }
    }

    // Create result object { name: string, score: number }
    napi_value result;
    napi_create_object(env, &result);

    napi_value nameVal, scoreVal;
    napi_create_string_utf8(env, bestName.c_str(), bestName.length(), &nameVal);
    napi_create_double(env, bestScore > 0 ? bestScore : 0.0, &scoreVal);

    napi_set_named_property(env, result, "name", nameVal);
    napi_set_named_property(env, result, "score", scoreVal);

    return result;
}

/**
 * getBestMatches(embedding: Float32Array, threshold: number, topN: number): SpeakerMatch[]
 */
static napi_value GetBestMatches(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 3) {
        napi_throw_error(env, nullptr, "getBestMatches requires (embedding, threshold, topN)");
        return nullptr;
    }

    float *embData = nullptr;
    size_t embLen = 0;
    if (!NapiGetFloat32Array(env, args[0], &embData, &embLen) || embLen != EMBEDDING_DIM) {
        napi_throw_error(env, nullptr, "embedding must be a Float32Array of 192 dimensions");
        return nullptr;
    }

    double threshold = 0.5;
    napi_get_value_double(env, args[1], &threshold);
    int32_t topN = 3;
    napi_get_value_int32(env, args[2], &topN);

    // Collect matches above threshold
    std::vector<std::pair<std::string, double>> matches;
    for (auto &pair : g_speakers) {
        double score = CosineSimilarity(embData, pair.second.data(), EMBEDDING_DIM);
        if (score >= threshold) {
            matches.push_back({pair.first, score});
        }
    }

    // Sort by score descending
    std::sort(matches.begin(), matches.end(),
        [](const auto &a, const auto &b) { return a.second > b.second; });

    // Limit to topN
    if (matches.size() > static_cast<size_t>(topN)) {
        matches.resize(topN);
    }

    // Create result array
    napi_value result;
    napi_create_array_with_length(env, matches.size(), &result);

    for (size_t i = 0; i < matches.size(); i++) {
        napi_value obj;
        napi_create_object(env, &obj);

        napi_value nameVal, scoreVal;
        napi_create_string_utf8(env, matches[i].first.c_str(), matches[i].first.length(), &nameVal);
        napi_create_double(env, matches[i].second, &scoreVal);

        napi_set_named_property(env, obj, "name", nameVal);
        napi_set_named_property(env, obj, "score", scoreVal);
        napi_set_element(env, result, i, obj);
    }

    return result;
}

/**
 * verifySpeaker(name: string, embedding: Float32Array, threshold: number): boolean
 */
static napi_value VerifySpeaker(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 3) {
        napi_throw_error(env, nullptr, "verifySpeaker requires (name, embedding, threshold)");
        return nullptr;
    }

    std::string name = NapiGetString(env, args[0]);

    float *embData = nullptr;
    size_t embLen = 0;
    if (!NapiGetFloat32Array(env, args[1], &embData, &embLen) || embLen != EMBEDDING_DIM) {
        napi_throw_error(env, nullptr, "embedding must be a Float32Array of 192 dimensions");
        return nullptr;
    }

    double threshold = 0.6;
    napi_get_value_double(env, args[2], &threshold);

    bool verified = false;
    auto it = g_speakers.find(name);
    if (it != g_speakers.end()) {
        double score = CosineSimilarity(embData, it->second.data(), EMBEDDING_DIM);
        verified = score >= threshold;
    }

    napi_value result;
    napi_get_boolean(env, verified, &result);
    return result;
}

/**
 * exportSpeakerEmbedding(name: string): Float32Array | null
 */
static napi_value ExportSpeakerEmbedding(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 1) {
        napi_throw_error(env, nullptr, "exportSpeakerEmbedding requires name");
        return nullptr;
    }

    std::string name = NapiGetString(env, args[0]);

    auto it = g_speakers.find(name);
    if (it == g_speakers.end()) {
        napi_value null;
        napi_get_null(env, &null);
        return null;
    }

    return NapiCreateFloat32Array(env, it->second.data(), EMBEDDING_DIM);
}

/**
 * importSpeakerEmbedding(name: string, embedding: Float32Array): boolean
 */
static napi_value ImportSpeakerEmbedding(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 2) {
        napi_throw_error(env, nullptr, "importSpeakerEmbedding requires (name, embedding)");
        return nullptr;
    }

    std::string name = NapiGetString(env, args[0]);

    float *embData = nullptr;
    size_t embLen = 0;
    if (!NapiGetFloat32Array(env, args[1], &embData, &embLen) || embLen != EMBEDDING_DIM) {
        napi_throw_error(env, nullptr, "embedding must be a Float32Array of 192 dimensions");
        return nullptr;
    }

    // Copy embedding into storage
    std::vector<float> emb(embData, embData + EMBEDDING_DIM);
    g_speakers[name] = emb;

    napi_value result;
    napi_get_boolean(env, true, &result);
    return result;
}

// Module registration
EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        // Existing
        {"initModel", nullptr, InitModel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"extractEmbedding", nullptr, ExtractEmbedding, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"computeSimilarity", nullptr, ComputeSimilarity, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getEmbeddingDim", nullptr, GetEmbeddingDim, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isModelLoaded", nullptr, IsModelLoaded, nullptr, nullptr, nullptr, napi_default, nullptr},
        // Speaker Management
        {"registerSpeaker", nullptr, RegisterSpeaker, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"removeSpeaker", nullptr, RemoveSpeaker, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getAllSpeakers", nullptr, GetAllSpeakers, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getNumSpeakers", nullptr, GetNumSpeakers, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"containsSpeaker", nullptr, ContainsSpeaker, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"identifySpeaker", nullptr, IdentifySpeaker, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getBestMatches", nullptr, GetBestMatches, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"verifySpeaker", nullptr, VerifySpeaker, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"exportSpeakerEmbedding", nullptr, ExportSpeakerEmbedding, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"importSpeakerEmbedding", nullptr, ImportSpeakerEmbedding, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module voiceprintModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "voiceprint",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterVoiceprintModule(void) {
    napi_module_register(&voiceprintModule);
}
