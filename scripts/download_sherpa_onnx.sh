#!/bin/bash
# download_sherpa_onnx.sh
# Downloads sherpa-onnx HAR package and 3D-Speaker model for voiceprint recognition.
#
# Usage: ./scripts/download_sherpa_onnx.sh
#
# Prerequisites:
#   - ohpm (OpenHarmony Package Manager) installed and in PATH
#   - curl or wget available
#
# References:
#   - https://k2-fsa.github.io/sherpa/onnx/harmony-os/
#   - https://ohpm.openharmony.cn/#/cn/detail/sherpa_onnx

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# sherpa_onnx version
SHERPA_ONNX_VERSION="1.12.1"

# 3D-Speaker model for speaker identification
MODEL_NAME="3dspeaker_speech_eres2net_base_200k_sv_zh-cn_16k-common.onnx"
MODEL_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/${MODEL_NAME}"
MODEL_DIR="${PROJECT_ROOT}/entry/src/main/resources/rawfile/voiceprint"

# Silero VAD model for voice activity detection
VAD_MODEL_NAME="silero_vad.onnx"
VAD_MODEL_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/${VAD_MODEL_NAME}"
VAD_MODEL_DIR="${PROJECT_ROOT}/entry/src/main/resources/rawfile/vad"

echo "========================================"
echo " sherpa-onnx Setup for ClawdBotHarmony"
echo "========================================"
echo ""

# Step 1: Install sherpa_onnx HAR via ohpm
echo "[1/3] Installing sherpa_onnx@${SHERPA_ONNX_VERSION} via ohpm..."
if command -v ohpm &> /dev/null; then
    cd "$PROJECT_ROOT"
    ohpm install sherpa_onnx@${SHERPA_ONNX_VERSION}
    echo "  -> sherpa_onnx installed successfully."
else
    echo "  WARNING: ohpm not found in PATH."
    echo "  Please install ohpm or add it to PATH, then run:"
    echo "    cd ${PROJECT_ROOT} && ohpm install sherpa_onnx@${SHERPA_ONNX_VERSION}"
    echo ""
    echo "  Alternatively, add to entry/oh-package.json5:"
    echo '    "dependencies": { "sherpa_onnx": "'${SHERPA_ONNX_VERSION}'" }'
    echo ""
fi

# Step 2: Download 3D-Speaker model
echo ""
echo "[2/3] Downloading 3D-Speaker model (~38MB)..."
mkdir -p "$MODEL_DIR"

if [ -f "${MODEL_DIR}/${MODEL_NAME}" ]; then
    echo "  -> Model already exists at ${MODEL_DIR}/${MODEL_NAME}"
    echo "  -> Skipping download. Delete the file to re-download."
else
    echo "  -> Downloading from: ${MODEL_URL}"
    if command -v curl &> /dev/null; then
        curl -L --progress-bar -o "${MODEL_DIR}/${MODEL_NAME}" "$MODEL_URL"
    elif command -v wget &> /dev/null; then
        wget --show-progress -O "${MODEL_DIR}/${MODEL_NAME}" "$MODEL_URL"
    else
        echo "  ERROR: Neither curl nor wget found. Please download manually:"
        echo "  URL: ${MODEL_URL}"
        echo "  Save to: ${MODEL_DIR}/${MODEL_NAME}"
        exit 1
    fi
    echo "  -> Model downloaded successfully."
fi

# Step 3: Download Silero VAD model
echo ""
echo "[3/4] Downloading Silero VAD model (~629KB)..."
mkdir -p "$VAD_MODEL_DIR"

if [ -f "${VAD_MODEL_DIR}/${VAD_MODEL_NAME}" ]; then
    echo "  -> VAD model already exists at ${VAD_MODEL_DIR}/${VAD_MODEL_NAME}"
    echo "  -> Skipping download. Delete the file to re-download."
else
    echo "  -> Downloading from: ${VAD_MODEL_URL}"
    if command -v curl &> /dev/null; then
        curl -L --progress-bar -o "${VAD_MODEL_DIR}/${VAD_MODEL_NAME}" "$VAD_MODEL_URL"
    elif command -v wget &> /dev/null; then
        wget --show-progress -O "${VAD_MODEL_DIR}/${VAD_MODEL_NAME}" "$VAD_MODEL_URL"
    else
        echo "  ERROR: Neither curl nor wget found. Please download manually:"
        echo "  URL: ${VAD_MODEL_URL}"
        echo "  Save to: ${VAD_MODEL_DIR}/${VAD_MODEL_NAME}"
        exit 1
    fi
    echo "  -> VAD model downloaded successfully."
fi

# Step 4: Verify
echo ""
echo "[4/4] Verifying setup..."

if [ -f "${MODEL_DIR}/${MODEL_NAME}" ]; then
    MODEL_SIZE=$(wc -c < "${MODEL_DIR}/${MODEL_NAME}" 2>/dev/null || echo "unknown")
    echo "  -> Speaker model: ${MODEL_DIR}/${MODEL_NAME} (${MODEL_SIZE} bytes)"
else
    echo "  WARNING: Speaker model file not found."
fi

if [ -f "${VAD_MODEL_DIR}/${VAD_MODEL_NAME}" ]; then
    VAD_SIZE=$(wc -c < "${VAD_MODEL_DIR}/${VAD_MODEL_NAME}" 2>/dev/null || echo "unknown")
    echo "  -> VAD model: ${VAD_MODEL_DIR}/${VAD_MODEL_NAME} (${VAD_SIZE} bytes)"
else
    echo "  WARNING: VAD model file not found."
fi

echo ""
echo "========================================"
echo " Setup complete!"
echo "========================================"
echo ""
echo "Next steps:"
echo "  1. Open the project in DevEco Studio"
echo "  2. Sync the ohpm dependencies"
echo "  3. Build and run the project"
echo ""
echo "Model locations:"
echo "  Speaker: ${MODEL_DIR}/${MODEL_NAME}"
echo "  VAD: ${VAD_MODEL_DIR}/${VAD_MODEL_NAME}"
echo ""
echo "The models will be bundled in the HAP as rawfile resources."
