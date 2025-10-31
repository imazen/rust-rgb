#!/bin/bash
set +e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

CRATE_NAME=$1
CRATE_PATH=$2
TEST_TYPE=$3
TEST_REF=$4
REPO_OWNER=$5
REPO_NAME=$6
SOURCE=$7

# Convert Windows path to WSL path if needed
if [[ "$CRATE_PATH" == *:* ]] && command -v wslpath &> /dev/null; then
  CRATE_PATH=$(wslpath -a "$CRATE_PATH")
fi

# Use /workspace if it exists (Docker), otherwise use current directory
OUTPUT_DIR="${OUTPUT_DIR:-/workspace}"
if [ ! -d "$OUTPUT_DIR" ] || [ ! -w "$OUTPUT_DIR" ]; then
  OUTPUT_DIR="."
fi

# Install cargo-override
echo -e "${CYAN}Installing cargo-override...${NC}"
if ! cargo install cargo-override; then
  echo -e "${RED}Failed to install cargo-override. Please ensure you have a working Rust toolchain.${NC}"
  exit 1
fi
echo -e "${GREEN}cargo-override installed successfully.${NC}"

IFS=',' read -ra CRATES <<< "$8"

# Filter out empty entries
FILTERED_CRATES=()
for crate in "${CRATES[@]}"; do
  crate=$(echo "$crate" | xargs)
  [ -n "$crate" ] && FILTERED_CRATES+=("$crate")
done
CRATES=("${FILTERED_CRATES[@]}")

if [ ${#CRATES[@]} -eq 0 ]; then
  echo -e "${YELLOW}No downstream dependents to test${NC}"
  exit 0
fi

declare -A RESULTS
declare -A DURATIONS
declare -A ERRORS

echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}  ${BLUE}Downstream Compatibility Test${NC}                         ${CYAN}║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${MAGENTA}Repository:${NC} ${REPO_OWNER}/${REPO_NAME}"
echo -e "${MAGENTA}Crate:${NC} ${CRATE_NAME}"
echo -e "${MAGENTA}Testing:${NC} ${TEST_TYPE}"
echo -e "${MAGENTA}Ref:${NC} ${TEST_REF}"
echo -e "${MAGENTA}Dependents source:${NC} ${SOURCE}"
echo -e "${MAGENTA}Downstream crates:${NC} ${#CRATES[@]}"
echo ""
echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
echo ""

TOTAL_START=$(date +%s)

for crate in "${CRATES[@]}"; do
  echo -e "${BLUE}[$(date +%H:%M:%S)] Testing ${crate}...${NC}"
  START=$(date +%s)
  
  TEST_PROJ_NAME="test_${crate}"
  TEST_DIR="../${TEST_PROJ_NAME}"
  rm -rf "$TEST_DIR"

  # Create a new cargo project
  echo -e "  ${CYAN}Creating test project for ${crate}...${NC}"
  if ! cargo new --quiet "$TEST_DIR"; then
    RESULTS[$crate]="⚠"
    STATUS="SKIP"
    COLOR=$YELLOW
    ERRORS[$crate]="Failed to create test project"
    END=$(date +%s)
    DURATIONS[$crate]=$((END - START))
    echo -e "  ${COLOR}${RESULTS[$crate]} ${STATUS}${NC} (${DURATIONS[$crate]}s)"
    echo -e "${RED}${ERRORS[$crate]}${NC}"
    echo ""
    continue
  fi
  
  cd "$TEST_DIR"

  # Add the downstream crate as a dependency
  echo -e "  ${CYAN}Adding ${crate} as a dependency...${NC}"
  if ! cargo add "${crate}"; then
    RESULTS[$crate]="⚠"
    STATUS="SKIP"
    COLOR=$YELLOW
    ERRORS[$crate]="Failed to add dependency"
    cd ..
    rm -rf "$TEST_DIR"
    END=$(date +%s)
    DURATIONS[$crate]=$((END - START))
    echo -e "  ${COLOR}${RESULTS[$crate]} ${STATUS}${NC} (${DURATIONS[$crate]}s)"
    echo -e "${RED}${ERRORS[$crate]}${NC}"
    echo ""
    continue
  fi

  # Override the dependency to the local path
  echo -e "  ${CYAN}Overriding ${CRATE_NAME} dependency...${NC}"
  # We need to copy the source to a folder with the crate's name
  TEMP_CRATE_DIR="../${CRATE_NAME}"
  cp -r "$CRATE_PATH" "$TEMP_CRATE_DIR"

  if ! cargo override --path "$TEMP_CRATE_DIR" --registry "https://github.com/rust-lang/crates.io-index"; then
    RESULTS[$crate]="⚠"
    STATUS="SKIP"
    COLOR=$YELLOW
    ERRORS[$crate]="cargo override failed"
    cd ..
    rm -rf "$TEST_DIR"
    rm -rf "$TEMP_CRATE_DIR"
    END=$(date +%s)
    DURATIONS[$crate]=$((END - START))
    echo -e "  ${COLOR}${RESULTS[$crate]} ${STATUS}${NC} (${DURATIONS[$crate]}s)"
    echo -e "${RED}${ERRORS[$crate]}${NC}"
    echo ""
    continue
  fi
  
  echo -e "  ${CYAN}Printing Cargo.toml...${NC}"
  cat Cargo.toml

  echo -e "  ${CYAN}Checking...${NC}"
  
  TEST_OUTPUT=$(mktemp)
  if timeout 600 cargo check --all-targets > "$TEST_OUTPUT" 2>&1; then
    TEST_EXIT_CODE=0
  else
    TEST_EXIT_CODE=$?
  fi
  cat "$TEST_OUTPUT"
  echo -e "  ${CYAN}Testing...${NC}"
  
  TEST_OUTPUT=$(mktemp)
  if timeout 600 cargo test > "$TEST_OUTPUT" 2>&1; then
    TEST_EXIT_CODE=0
  else
    TEST_EXIT_CODE=$?
  fi
  cat "$TEST_OUTPUT"
  
  cd ..
  
  # Process test results
  if [ $TEST_EXIT_CODE -eq 0 ]; then
    RESULTS[$crate]="✓"
    STATUS="PASSED"
    COLOR=$GREEN
    ERRORS[$crate]=""
  elif [ $TEST_EXIT_CODE -eq 124 ]; then
    RESULTS[$crate]="⏱"
    STATUS="TIMEOUT"
    COLOR=$YELLOW
    ERRORS[$crate]="Check exceeded 10 minute timeout"
  else
    RESULTS[$crate]="✗"
    STATUS="FAILED"
    COLOR=$RED
    ERRORS[$crate]=$(tail -10 "$TEST_OUTPUT" | sed 's/^/    /')
  fi
  
  # Cleanup
  rm -rf "$TEST_DIR"
  rm -rf "$TEMP_CRATE_DIR"
  rm -f "$TEST_OUTPUT"
  
  END=$(date +%s)
  DURATIONS[$crate]=$((END - START))
  echo -e "  ${COLOR}${RESULTS[$crate]} ${STATUS}${NC} (${DURATIONS[$crate]}s)"
  
  if [ -n "${ERRORS[$crate]}" ] && [ "${#ERRORS[$crate]}" -lt 500 ]; then
    echo -e "${RED}${ERRORS[$crate]}${NC}"
  fi
  echo ""
done

TOTAL_END=$(date +%s)
TOTAL_DURATION=$((TOTAL_END - TOTAL_START))

echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}  ${BLUE}SUMMARY${NC}                                                ${CYAN}║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

PASSED=0; FAILED=0; TIMEOUT=0; SKIP=0

for crate in "${CRATES[@]}"; do
  case "${RESULTS[$crate]}" in
    "✓") 
      echo -e "${GREEN}✓${NC} $crate ${CYAN}(${DURATIONS[$crate]}s)${NC}"
      ((PASSED++))
      ;;
    "✗") 
      echo -e "${RED}✗${NC} $crate ${CYAN}(${DURATIONS[$crate]}s)${NC}"
      ((FAILED++))
      ;;
    "⏱") 
      echo -e "${YELLOW}⏱${NC} $crate ${CYAN}(${DURATIONS[$crate]}s)${NC}"
      ((TIMEOUT++))
      ;;
    *) 
      echo -e "${YELLOW}⚠${NC} $crate ${CYAN}(${DURATIONS[$crate]}s)${NC}"
      ((SKIP++))
      ;;
  esac
done

echo ""
echo -e "${MAGENTA}Results:${NC}"
echo -e "  ${GREEN}✓ Passed:${NC}  $PASSED"
echo -e "  ${RED}✗ Failed:${NC}  $FAILED"
echo -e "  ${YELLOW}⏱ Timeout:${NC} $TIMEOUT"
echo -e "  ${YELLOW}⚠ Skipped:${NC} $SKIP"
echo -e "  ${CYAN}⏱ Total:${NC}   ${TOTAL_DURATION}s"
echo ""

cat > "$OUTPUT_DIR/results.md" <<EOF
## 🧪 Downstream Compatibility Test Results

**Repository:** \`${REPO_OWNER}/${REPO_NAME}\`  
**Crate:** \`${CRATE_NAME}\`  
**Testing:** ${TEST_TYPE}  
**Ref:** \`${TEST_REF}\`  
**Dependents source:** ${SOURCE}

### Results

| Crate | Status | Duration |
|-------|--------|----------|
EOF

for crate in "${CRATES[@]}"; do
  status_emoji="${RESULTS[$crate]}"
  status_text=""
  case "$status_emoji" in
    "✓") status_text="Passed";;
    "✗") status_text="Failed";;
    "⏱") status_text="Timeout";;
    *) status_text="Skipped";;
  esac
  
  echo "| \`$crate\` | $status_emoji $status_text | ${DURATIONS[$crate]}s |" >> "$OUTPUT_DIR/results.md"
done

cat >> "$OUTPUT_DIR/results.md" <<EOF

### Summary

- ✓ **Passed:** $PASSED
- ✗ **Failed:** $FAILED
- ⏱ **Timeout:** $TIMEOUT
- ⚠ **Skipped:** $SKIP
- ⏱ **Total time:** ${TOTAL_DURATION}s

---
<sub>Generated by downstream-test at $(date -u +"%Y-%m-%d %H:%M:%S UTC")</sub>
EOF

cat > "$OUTPUT_DIR/stats.env" <<EOF
PASSED=$PASSED
FAILED=$FAILED
TIMEOUT=$TIMEOUT
SKIP=$SKIP
TOTAL_DURATION=$TOTAL_DURATION
EOF

cat "$OUTPUT_DIR/results.md"

# Exit with failure if any tests failed
[ $FAILED -eq 0 ]