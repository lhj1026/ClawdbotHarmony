#!/usr/bin/env bash
# 情景智能测试套件 - 一键运行所有测试
# 用法: bash tests/context_ai/run_all.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0
FAILED_FILES=()

echo -e "${CYAN}=== 情景智能测试套件 ===${NC}"
echo ""

# Unit tests
echo -e "${CYAN}── Unit Tests ──${NC}"
for f in "$SCRIPT_DIR"/unit/test_*.js; do
  fname=$(basename "$f")
  if node "$f"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_FILES+=("unit/$fname")
  fi
done

# Scenario tests
echo -e "${CYAN}── Scenario Tests ──${NC}"
for f in "$SCRIPT_DIR"/scenario/test_*.js; do
  fname=$(basename "$f")
  if node "$f"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_FILES+=("scenario/$fname")
  fi
done

# Summary
echo ""
echo -e "${CYAN}=== Summary ===${NC}"
echo -e "${GREEN}  $PASS files passing${NC}"
if [ $FAIL -gt 0 ]; then
  echo -e "${RED}  $FAIL files failing${NC}"
  for ff in "${FAILED_FILES[@]}"; do
    echo -e "${RED}    - $ff${NC}"
  done
  exit 1
else
  echo -e "${GREEN}  All tests passed!${NC}"
fi
