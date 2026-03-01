#!/bin/bash
# ============================================
# ClawdbotHarmony Pre-Commit Verification Tests
# 每次 commit 前自动运行的检查脚本
# ============================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

PASS="${GREEN}✓${NC}"
FAIL="${RED}✗${NC}"
ERRORS=0

# Resolve project root (works whether called from repo root or .git/hooks)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ "$SCRIPT_DIR" == */.git/hooks ]]; then
  PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
else
  PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  ClawdbotHarmony Pre-Commit Tests${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# ------------------------------------------
# Test 1: Version Consistency
# ------------------------------------------
echo -e "${YELLOW}[1/5] Checking version consistency...${NC}"

V_APP=$(grep -o '"versionName"[[:space:]]*:[[:space:]]*"[^"]*"' "$PROJECT_ROOT/AppScope/app.json5" | grep -o '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*' || true)
V_NODE=$(grep -o "APP_VERSION[[:space:]]*=[[:space:]]*'[^']*'" "$PROJECT_ROOT/entry/src/main/ets/service/gateway/NodeRuntime.ets" | grep -o '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*' || true)
V_INDEX=$(grep -o "Text('v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*')" "$PROJECT_ROOT/entry/src/main/ets/pages/Index.ets" | grep -o '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*' || true)
# 版本号在 generated/Changelog.ets 中定义为 APP_VERSION（AboutRoutePage.ets 引用它）
V_SETTINGS=$(grep -o "APP_VERSION[[:space:]]*:[[:space:]]*string[[:space:]]*=[[:space:]]*'[^']*'" "$PROJECT_ROOT/entry/src/main/ets/generated/Changelog.ets" | grep -o '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*' | head -1 || true)

VERSION_OK=true
if [ -z "$V_APP" ] || [ -z "$V_NODE" ] || [ -z "$V_INDEX" ] || [ -z "$V_SETTINGS" ]; then
  echo -e "  ${FAIL} Could not extract version from one or more locations"
  VERSION_OK=false
elif [ "$V_APP" != "$V_NODE" ] || [ "$V_APP" != "$V_INDEX" ] || [ "$V_APP" != "$V_SETTINGS" ]; then
  VERSION_OK=false
fi

if [ "$VERSION_OK" = true ]; then
  echo -e "  ${PASS} All versions match: ${GREEN}${V_APP}${NC}"
else
  echo -e "  ${FAIL} Version mismatch detected!"
  echo -e "    app.json5:        ${V_APP:-MISSING}"
  echo -e "    NodeRuntime.ets:  ${V_NODE:-MISSING}"
  echo -e "    Index.ets:        ${V_INDEX:-MISSING}"
  echo -e "    Changelog.ets:    ${V_SETTINGS:-MISSING}"
  ERRORS=$((ERRORS + 1))
fi

# ------------------------------------------
# Test 2: Critical Files Exist
# ------------------------------------------
echo -e "${YELLOW}[2/5] Checking critical files...${NC}"

CRITICAL_FILES=(
  "AppScope/app.json5"
  "build-profile.json5"
  "hvigorfile.ts"
  "entry/hvigorfile.ts"
  "entry/build-profile.json5"
  "entry/oh-package.json5"
  "entry/src/main/module.json5"
  "entry/src/main/ets/pages/Index.ets"
  "entry/src/main/ets/pages/ChatPage.ets"
  "entry/src/main/ets/pages/SettingsPage.ets"
  "entry/src/main/ets/components/MessageBubble.ets"
  "entry/src/main/ets/service/gateway/NodeRuntime.ets"
  "entry/src/main/ets/service/gateway/GatewaySession.ets"
)

FILES_OK=true
for f in "${CRITICAL_FILES[@]}"; do
  if [ ! -f "$PROJECT_ROOT/$f" ]; then
    echo -e "  ${FAIL} Missing: $f"
    FILES_OK=false
    ERRORS=$((ERRORS + 1))
  fi
done

if [ "$FILES_OK" = true ]; then
  echo -e "  ${PASS} All ${#CRITICAL_FILES[@]} critical files present"
fi

# ------------------------------------------
# Test 3: UI Resource Files Check
# ------------------------------------------
echo -e "${YELLOW}[3/5] Checking UI resource files...${NC}"

RESOURCE_DIR="entry/src/main/resources/base/media"
REQUIRED_RESOURCES=(
  "${RESOURCE_DIR}/icon.png"
  "${RESOURCE_DIR}/startIcon.png"
  "${RESOURCE_DIR}/talkmode.jpg"
  "${RESOURCE_DIR}/ic_talk_mode.png"
  "${RESOURCE_DIR}/ic_hangup.png"
)

RESOURCE_OK=true
MISSING_RESOURCES=()
UNTRACKED_RESOURCES=()

for res in "${REQUIRED_RESOURCES[@]}"; do
  if [ ! -f "$PROJECT_ROOT/$res" ]; then
    RESOURCE_OK=false
    MISSING_RESOURCES+=("$res")
  elif ! git -C "$PROJECT_ROOT" ls-files --error-unmatch "$res" >/dev/null 2>&1; then
    RESOURCE_OK=false
    UNTRACKED_RESOURCES+=("$res")
  fi
done

# Also check if any resource was deleted in staged changes
DELETED_RESOURCES=$(git -C "$PROJECT_ROOT" diff --cached --name-only --diff-filter=D 2>/dev/null | grep "^${RESOURCE_DIR}/" || true)
if [ -n "$DELETED_RESOURCES" ]; then
  RESOURCE_OK=false
fi

if [ "$RESOURCE_OK" = true ]; then
  echo -e "  ${PASS} All ${#REQUIRED_RESOURCES[@]} UI resources present and tracked"
else
  for res in "${MISSING_RESOURCES[@]}"; do
    echo -e "  ${FAIL} Missing on disk: $res"
    ERRORS=$((ERRORS + 1))
  done
  for res in "${UNTRACKED_RESOURCES[@]}"; do
    echo -e "  ${FAIL} Not tracked by git: $res"
    ERRORS=$((ERRORS + 1))
  done
  if [ -n "$DELETED_RESOURCES" ]; then
    echo "$DELETED_RESOURCES" | while read -r del; do
      echo -e "  ${FAIL} Staged for deletion: $del"
    done
    ERRORS=$((ERRORS + 1))
  fi
fi

# ------------------------------------------
# Test 4: Sensitive Data Check
# ------------------------------------------
echo -e "${YELLOW}[4/5] Checking for sensitive data in staged files...${NC}"

SENSITIVE_OK=true
# Check staged .ets/.ts files for hardcoded secrets
STAGED_FILES=$(git -C "$PROJECT_ROOT" diff --cached --name-only --diff-filter=ACM 2>/dev/null | grep -E '\.(ets|ts|json5?)$' || true)

if [ -n "$STAGED_FILES" ]; then
  for sf in $STAGED_FILES; do
    FULL_PATH="$PROJECT_ROOT/$sf"
    if [ -f "$FULL_PATH" ]; then
      # Check for common secret patterns (skip comments and known config files)
      if echo "$sf" | grep -qE '(SettingsPage|build-profile|local\.properties)'; then
        continue
      fi
      SECRETS=$(grep -nE '(sk-[a-zA-Z0-9]{20,}|AKIA[A-Z0-9]{16}|ghp_[a-zA-Z0-9]{36})' "$FULL_PATH" 2>/dev/null || true)
      if [ -n "$SECRETS" ]; then
        echo -e "  ${FAIL} Possible secret in $sf:"
        echo "    $SECRETS"
        SENSITIVE_OK=false
        ERRORS=$((ERRORS + 1))
      fi
    fi
  done
fi

if [ "$SENSITIVE_OK" = true ]; then
  echo -e "  ${PASS} No hardcoded secrets detected"
fi

# ------------------------------------------
# Test 4: Build Verification
# ------------------------------------------
echo -e "${YELLOW}[5/5] Building project (compile check)...${NC}"

# Build using cmd.exe (WSL-compatible) or powershell.exe (Git for Windows)
WIN_PROJECT="C:\\Users\\Liuho\\ClawdbotHarmony"
CMD_EXE="/mnt/c/Windows/System32/cmd.exe"

if [ -f "$CMD_EXE" ]; then
  # WSL 环境：直接调用 cmd.exe
  BUILD_OUTPUT=$("$CMD_EXE" /c "cd /d C:\\Users\\Liuho\\ClawdBotHarmony && C:\\Users\\Liuho\\ClawdBotHarmony\\scripts\\_build.bat" 2>&1) || true
else
  # Git for Windows 环境：调用 powershell.exe
  BUILD_OUTPUT=$(powershell.exe -Command "Set-Location '${WIN_PROJECT}'; cmd.exe /c 'build_debug.bat build-only'" 2>&1) || true
fi
BUILD_EXIT=$?

if echo "$BUILD_OUTPUT" | grep -q "BUILD SUCCESSFUL"; then
  echo -e "  ${PASS} Build successful"
elif [ $BUILD_EXIT -eq 0 ]; then
  echo -e "  ${PASS} Build successful"
else
  echo -e "  ${FAIL} Build failed!"
  # Show last few relevant lines
  echo "$BUILD_OUTPUT" | grep -E '(ERROR|FAILED|error:)' | tail -10 | while read -r line; do
    echo -e "    ${RED}${line}${NC}"
  done
  ERRORS=$((ERRORS + 1))
fi

# ------------------------------------------
# Summary
# ------------------------------------------
echo ""
echo -e "${CYAN}----------------------------------------${NC}"
if [ $ERRORS -eq 0 ]; then
  echo -e "${GREEN}  All checks passed! Ready to commit.${NC}"
  echo -e "${CYAN}----------------------------------------${NC}"
  echo ""
  exit 0
else
  echo -e "${RED}  ${ERRORS} check(s) failed. Commit blocked.${NC}"
  echo -e "${CYAN}----------------------------------------${NC}"
  echo ""
  exit 1
fi
