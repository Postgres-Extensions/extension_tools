#!/usr/bin/env bash
# Helper script for make results target
# Copies .out files from results/ to expected/, excluding those with output/*.source counterparts

set -e

TESTDIR="${1:-test}"
TESTOUT="${2:-${TESTDIR}}"

mkdir -p "${TESTDIR}/expected"

# Use nullglob so globs that don't match return nothing instead of the literal pattern
shopt -s nullglob

for result_file in "${TESTOUT}/results"/*.out; do
	test_name=$(basename "$result_file" .out)
	
	# Check if this file has a corresponding output/*.source file
	# Only consider non-empty source files (empty files are likely leftovers from pg_regress)
	if [ -f "${TESTDIR}/output/${test_name}.source" ] && [ -s "${TESTDIR}/output/${test_name}.source" ]; then
		echo "WARNING: ${TESTOUT}/results/${test_name}.out exists but will NOT be copied" >&2
		echo "         (excluded because ${TESTDIR}/output/${test_name}.source exists)" >&2
	else
		# Copy the file - it doesn't have an output/*.source counterpart
		cp "$result_file" "${TESTDIR}/expected/${test_name}.out"
	fi
done

