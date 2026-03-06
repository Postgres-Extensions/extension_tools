#!/bin/bash
# lib.sh - Common utility functions for pgxntool scripts
#
# This file is meant to be sourced by other scripts, not executed directly.
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# =============================================================================
# SETUP FILES CONFIGURATION
# =============================================================================
# Files copied by setup.sh and tracked by update-setup-files.sh for sync updates.
# Format: "source_in_pgxntool:destination_in_project"
# =============================================================================
SETUP_FILES=(
    "_.gitignore:.gitignore"
    "test/deps.sql:test/deps.sql"
)

# Symlinks created by setup.sh and verified by update-setup-files.sh
# Format: "destination:target"
SETUP_SYMLINKS=(
    "test/pgxntool:../pgxntool/test/pgxntool"
)

# Error function - outputs to stderr but doesn't exit
# Usage: error "message"
error() {
    echo "ERROR: $*" >&2
}

# Die function - outputs error message and exits with specified code
# Usage: die EXIT_CODE "message"
die() {
    local exit_code=$1
    shift
    error "$@"
    exit $exit_code
}

# Debug function
# Usage: debug LEVEL "message"
# Outputs message to stderr if DEBUG >= LEVEL
# Debug levels use multiples of 10 (10, 20, 30, 40, etc.) to allow for easy expansion
#   - 10: Critical errors, important warnings
#   - 20: Warnings, significant state changes
#   - 30: General debugging, function entry/exit, array operations
#   - 40: Verbose details, loop iterations
#   - 50+: Maximum verbosity
# Enable with: DEBUG=30 scriptname.sh
debug() {
    local level=$1
    shift
    local message="$*"

    if [ "${DEBUG:-0}" -ge "$level" ]; then
        echo "DEBUG[$level]: $message" >&2
    fi
}
