#!/bin/bash
# eval_setup_config.sh
# Configuration and constants for HumanEval Rust evaluation setup
# Version: 1.3.5
#
# This file contains all configuration variables and constants used by
# the evaluation setup scripts. Source this file first before other modules.

# Colors for output
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export NC='\033[0m' # No Color

# Configuration
export PYTHON_VERSION="${PYTHON_VERSION:-3.12.11}"
export VENV_DIR="${VENV_DIR:-$HOME/.venvs/sigilderg-humaneval}"
export BASE_MODEL="${BASE_MODEL:-meta-llama/Meta-Llama-3.1-8B-Instruct}"
export CHECKPOINT_PATH="${CHECKPOINT_PATH:-Superuser666-Sigil/Llama-3.1-8B-Instruct-Rust-QLora/checkpoint-9000}"
export OUTPUT_DIR="${OUTPUT_DIR:-./humaneval_results}"
export NUM_SAMPLES="${NUM_SAMPLES:-100}"
export K_VALUES="${K_VALUES:-1,10,100}"
export SANDBOX_MODE="${SANDBOX_MODE:-}"    # Empty = auto-detect, or "docker", "firejail", "none"

# Reproducibility toggles
export SKIP_ENV_CHECK="${SKIP_ENV_CHECK:-0}"  # Set to 1 to bypass strict Ubuntu 22.04 + H100 check
export NONINTERACTIVE="${NONINTERACTIVE:-0}"  # Set to 1 for CI/non-interactive runs (no prompts)

# Note: Script now runs BOTH policy and non-policy modes automatically
# Results are organized in sub-folders: no-policy/ and policy/

