#!/usr/bin/env bash
# Test suite for pdf_shrink.sh
set -uo pipefail  # Remove -e to allow tests to fail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCRIPT="./pdf_shrink.sh"
TESTS_PASSED=0
TESTS_FAILED=0

# Test helper functions
pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
    ((TESTS_PASSED++))
}

fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    echo "  → $2"
    ((TESTS_FAILED++))
}

info() {
    echo -e "${YELLOW}ℹ${NC}: $1"
}

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up test files..."
    rm -f test_output*.pdf test_*.pdf
    echo "Removed test files"
}

trap cleanup EXIT

# Run tests
echo "=============================================="
echo "PDF Shrink Script Test Suite"
echo "=============================================="
echo ""

# Check if test.pdf exists
if [[ ! -f test.pdf ]]; then
    info "Note: test.pdf not found in current directory"
    info "Tests requiring test.pdf will be skipped (tests 5-10)"
    info "Tests 1-4 will still run (error handling tests)"
    echo ""
fi

# Test 1: Help message
info "Test 1: Help message"
HELP_OUTPUT="$($SCRIPT -h 2>&1)" || true
if echo "$HELP_OUTPUT" | grep -q "Usage:"; then
    pass "Help message displays"
else
    fail "Help message not displaying" "Missing Usage text"
fi
echo ""

# Test 2: Missing input file
info "Test 2: Error handling - missing input"
ERROR_OUTPUT="$($SCRIPT -i nonexistent.pdf -t 1M 2>&1)" || true
if echo "$ERROR_OUTPUT" | grep -q "Input file not found"; then
    pass "Correctly detects missing input file"
else
    fail "Does not detect missing file" "Should show 'Input file not found'"
fi
echo ""

# Test 3: Missing target size
info "Test 3: Error handling - missing target size"
ERROR_OUTPUT="$($SCRIPT -i test.pdf 2>&1)" || true
if echo "$ERROR_OUTPUT" | grep -q "Missing parameters"; then
    pass "Correctly detects missing target size"
else
    fail "Does not detect missing target" "Should show 'Missing parameters'"
fi
echo ""

# Test 4: Invalid target size format
info "Test 4: Invalid size format"
ERROR_OUTPUT="$($SCRIPT -i test.pdf -t invalid 2>&1)" || true
if echo "$ERROR_OUTPUT" | grep -q "Invalid target size"; then
    pass "Rejects invalid size format"
else
    fail "Does not validate size format" "Should reject 'invalid'"
fi
echo ""

# Test 5: Basic functionality - creates output file
info "Test 5: Basic compression (creates output file)"
if [[ ! -f test.pdf ]]; then
    info "Skipping test 5: test.pdf not found"
else
    if $SCRIPT -i test.pdf -t 1M --no-ocr -o test_output 2>&1 >/dev/null; then
        if [[ -f test_output_bw.pdf ]]; then
            SIZE=$(stat -f%z test_output_bw.pdf)
            if (( SIZE > 0 )); then
                pass "Creates valid output file (${SIZE} bytes)"
            else
                fail "Output file is empty or invalid" "Size: ${SIZE} bytes"
            fi
        else
            fail "Output file not created" "test_output_bw.pdf missing"
        fi
    else
        fail "Script failed to run" "Exit code $?"
    fi
fi
echo ""

# Test 6: OCR version
info "Test 6: OCR version (if ocrmypdf available)"
if [[ ! -f test.pdf ]]; then
    info "Skipping test 6: test.pdf not found"
elif command -v ocrmypdf >/dev/null 2>&1; then
    if $SCRIPT -i test.pdf -t 1M -o test_output_ocr 2>&1 >/dev/null; then
        if [[ -f test_output_ocr_bw_ocr.pdf ]]; then
            pass "OCR version created successfully"
        else
            fail "OCR output not created" "test_output_ocr_bw_ocr.pdf missing"
        fi
    else
        fail "OCR script failed" "Exit code $?"
    fi
else
    info "Skipping OCR test (ocrmypdf not available)"
fi
echo ""

# Test 7: Size notation (KB)
info "Test 7: Size notation with KB"
if [[ ! -f test.pdf ]]; then
    info "Skipping test 7: test.pdf not found"
else
    if $SCRIPT -i test.pdf -t 2000k --no-ocr -o test_output_kb 2>&1 >/dev/null; then
        if [[ -f test_output_kb_bw.pdf ]]; then
            SIZE=$(stat -f%z test_output_kb_bw.pdf)
            if (( SIZE > 0 )); then
                pass "KB notation accepted and processed (${SIZE} bytes)"
            else
                fail "KB notation failed" "Created invalid file"
            fi
        else
            fail "Output not created with KB notation" "test_output_kb_bw.pdf missing"
        fi
    else
        fail "KB notation failed" "Exit code $?"
    fi
fi
echo ""

# Test 8: Size notation (MB)
info "Test 8: Size notation with MB"
if [[ ! -f test.pdf ]]; then
    info "Skipping test 8: test.pdf not found"
else
    if $SCRIPT -i test.pdf -t 2M --no-ocr -o test_output_mb 2>&1 >/dev/null; then
        if [[ -f test_output_mb_bw.pdf ]]; then
            pass "MB notation accepted and processed"
        else
            fail "MB notation failed" "test_output_mb_bw.pdf missing"
        fi
    else
        fail "MB notation failed" "Exit code $?"
    fi
fi
echo ""

# Test 9: DPI range limits
info "Test 9: DPI range parameters"
if [[ ! -f test.pdf ]]; then
    info "Skipping test 9: test.pdf not found"
else
    if $SCRIPT -i test.pdf -t 500k --min-dpi 100 --max-dpi 150 --no-ocr -o test_output_dpi 2>&1 >/dev/null; then
        if [[ -f test_output_dpi_bw.pdf ]]; then
            pass "DPI range parameters respected"
        else
            fail "DPI range failed" "test_output_dpi_bw.pdf missing"
        fi
    else
        fail "DPI range parameters failed" "Exit code $?"
    fi
fi
echo ""

# Test 10: Verbose mode
info "Test 10: Verbose mode"
if [[ ! -f test.pdf ]]; then
    info "Skipping test 10: test.pdf not found"
else
    VERBOSE_OUTPUT="$($SCRIPT -i test.pdf -t 1M --verbose --no-ocr -o test_output_verbose 2>&1)" || true
    if echo "$VERBOSE_OUTPUT" | grep -q "Rasterizing all pages"; then
        pass "Verbose mode shows detailed output"
    else
        fail "Verbose mode not working" "Should show rasterization progress"
    fi
fi
echo ""

# Summary
echo ""
echo "=============================================="
echo "Test Summary"
echo "=============================================="
echo "Tests passed: ${TESTS_PASSED}"
echo "Tests failed: ${TESTS_FAILED}"
echo ""

if (( TESTS_FAILED == 0 )); then
    echo -e "${GREEN}All tests passed! ✓${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed. ${NC}"
    exit 1
fi

