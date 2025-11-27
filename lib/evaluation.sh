#!/bin/bash
# lib/evaluation.sh
#
# Evaluation script generation.
#
# Copies the Python evaluation script from scripts/evaluate_humaneval.py to the venv
# directory and makes it executable. The Python script handles model loading, sample
# generation, evaluation, and report generation.
#
# Copyright (c) 2025 Dave Tofflemire, SigilDERG Project
# Version: 1.3.6

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/eval_setup_config.sh"
source "$SCRIPT_DIR/lib/logging.sh"

# Create evaluation script
create_evaluation_script() {
    log_info "Creating evaluation script..."
    
    # Path to the extracted Python script
    PYTHON_SCRIPT_SOURCE="$SCRIPT_DIR/scripts/evaluate_humaneval.py"
    PYTHON_SCRIPT_DEST="$VENV_DIR/evaluate_humaneval.py"
    
    # Check if source script exists
    if [ ! -f "$PYTHON_SCRIPT_SOURCE" ]; then
        error_exit "Python evaluation script not found at: $PYTHON_SCRIPT_SOURCE"
    fi
    
    # Copy the script to venv directory
    cp "$PYTHON_SCRIPT_SOURCE" "$PYTHON_SCRIPT_DEST" || error_exit "Failed to copy evaluation script"
    
    # Make it executable
    chmod +x "$PYTHON_SCRIPT_DEST" || error_exit "Failed to make evaluation script executable"
    
    log_success "Evaluation script created"
}

