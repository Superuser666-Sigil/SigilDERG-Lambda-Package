#!/bin/bash
# lib/tmux.sh
#
# tmux session management for evaluation execution.
#
# Manages tmux sessions for persistent evaluation runs that can survive
# disconnections. Creates a detached tmux session with the evaluation script,
# ensuring Rust environment is properly sourced. Falls back to foreground
# execution if tmux is not available.
#
# Copyright (c) 2025 Dave Tofflemire, SigilDERG Project
# Version: 1.3.5

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/eval_setup_config.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/environment.sh"
source "$SCRIPT_DIR/lib/evaluation.sh"

# Check tmux availability
check_tmux() {
    if command_exists tmux; then
        log_success "tmux is available"
        return 0
    else
        log_warning "tmux not found. Install with: sudo apt-get install tmux"
        return 1
    fi
}

# Run evaluation in tmux
run_evaluation() {
    log_info "Starting evaluation in tmux session..."
    
    # Check if tmux is available
    if ! check_tmux; then
        log_warning "tmux not available, running evaluation in current session (not persistent)"
        log_info "To install tmux: sudo apt-get install tmux"
        
        # Fallback: run without tmux
        # Note: TOKENIZERS_PARALLELISM is set in Python script only for evaluation phase
        # Note: Script now runs BOTH policy and non-policy modes automatically
        source "$VENV_DIR/bin/activate"

        PY_ARGS=(
            "$VENV_DIR/evaluate_humaneval.py"
            --base-model "$BASE_MODEL"
            --checkpoint-path "$CHECKPOINT_PATH"
            --output-dir "$OUTPUT_DIR"
            --num-samples "$NUM_SAMPLES"
            --k-values "$K_VALUES"
        )
        if [ -n "${SANDBOX_MODE:-}" ]; then
            PY_ARGS+=( --sandbox-mode "$SANDBOX_MODE" )
            log_info "Using sandbox mode: $SANDBOX_MODE"
        else
            log_info "Sandbox mode: auto-detect (will use Docker if available, otherwise Firejail or none)"
        fi

        python "${PY_ARGS[@]}" || error_exit "Evaluation failed"
        
        log_success "Evaluation completed! Results in: $OUTPUT_DIR"
        return
    fi
    
    # Create tmux session name
    TMUX_SESSION="sigilderg-eval"
    
    # Check if session already exists
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        if [ "${NONINTERACTIVE:-0}" = "1" ]; then
            log_warning "tmux session '$TMUX_SESSION' already exists; killing and recreating it (NONINTERACTIVE=1)"
            tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
        else
        log_warning "tmux session '$TMUX_SESSION' already exists"
        log_info "Attaching to existing session. Use 'tmux kill-session -t $TMUX_SESSION' to kill it first if needed."
        log_info "Or attach manually with: tmux attach -t $TMUX_SESSION"
        
        read -p "Kill existing session and create new one? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
        else
            log_info "Attaching to existing session..."
            tmux attach -t "$TMUX_SESSION"
            return
            fi
        fi
    fi
    
    # Create new tmux session and run evaluation
    log_info "Creating tmux session '$TMUX_SESSION'..."
    
    # Build evaluation command with optional flags (use venv python explicitly)
    # Note: Script now runs BOTH policy and non-policy modes automatically
    EVAL_CMD="$VENV_DIR/bin/python $VENV_DIR/evaluate_humaneval.py"
    EVAL_CMD="$EVAL_CMD --base-model $BASE_MODEL"
    EVAL_CMD="$EVAL_CMD --checkpoint-path $CHECKPOINT_PATH"
    EVAL_CMD="$EVAL_CMD --output-dir $OUTPUT_DIR"
    EVAL_CMD="$EVAL_CMD --num-samples $NUM_SAMPLES"
    EVAL_CMD="$EVAL_CMD --k-values $K_VALUES"
    
    # Add sandbox mode if specified (from environment or fallback selection)
    if [ -n "${SANDBOX_MODE:-}" ]; then
        EVAL_CMD="$EVAL_CMD --sandbox-mode $SANDBOX_MODE"
        log_info "Using sandbox mode: $SANDBOX_MODE"
    else
        log_info "Sandbox mode: auto-detect (will use Docker if available, otherwise Firejail or none)"
    fi
    
    # Note: No --no-policy or --policy-only flags needed - script runs both automatically
    
    # Create a script that will run in tmux
    EVAL_SCRIPT=$(mktemp)
    cat > "$EVAL_SCRIPT" << EOF
#!/bin/bash
# Evaluation script to run in tmux
set -e  # Exit on error

# Note: TOKENIZERS_PARALLELISM is set in Python script only for evaluation phase
# (not during generation, which uses batched tokenization without forking)

# Source bashrc to get pyenv and other environment variables
if [ -f ~/.bashrc ]; then
    source ~/.bashrc
fi

# Source Rust environment (required for evaluation)
if [ -f "\$HOME/.cargo/env" ]; then
    . "\$HOME/.cargo/env"
fi

# Verify rustc is available (critical for evaluation)
if ! command -v rustc >/dev/null 2>&1; then
    echo "ERROR: rustc not found in PATH. Evaluation cannot proceed."
    echo "Please ensure Rust is installed and ~/.cargo/env is sourced."
    exit 1
fi

# Change to home directory
cd "\$HOME"

# Activate virtual environment
if [ -f "$VENV_DIR/bin/activate" ]; then
    source "$VENV_DIR/bin/activate"
else
    echo "ERROR: Virtual environment not found at $VENV_DIR"
    exit 1
fi

# Verify venv is activated and torch is available
if ! python -c "import torch" 2>/dev/null; then
    echo "ERROR: torch not found in virtual environment"
    echo "Python path: \$(which python)"
    echo "Virtual env: \$VIRTUAL_ENV"
    exit 1
fi

echo "=========================================="
echo "HumanEval Rust Evaluation"
echo "Running in tmux session: $TMUX_SESSION"
echo "=========================================="
echo "Python: \$(which python)"
echo "Python version: \$(python --version)"
echo "Virtual env: \$VIRTUAL_ENV"
echo "Output directory: $OUTPUT_DIR"
echo "Samples per task: $NUM_SAMPLES"
echo "K values: $K_VALUES"
echo "Sandbox mode: ${SANDBOX_MODE:-auto-detect}"
echo "Evaluation modes: BOTH (no-policy first, then policy)"
echo "Results will be organized in sub-folders: no-policy/ and policy/"
echo ""
echo "This session will persist if you disconnect."
echo "To reattach: tmux attach -t $TMUX_SESSION"
echo "To detach: Press Ctrl+B, then D"
echo "=========================================="
echo ""

# Run the evaluation command (already uses venv python explicitly)
$EVAL_CMD

EXIT_CODE=\$?
echo ""
echo "=========================================="
if [ \$EXIT_CODE -eq 0 ]; then
    echo "Evaluation completed successfully!"
    echo "Results saved to: $OUTPUT_DIR"
    echo "  - no-policy/ (no policy enforcement)"
    echo "    - comparison_report.md (human-readable)"
    echo "    - metrics.json (machine-readable)"
    echo "  - policy/ (policy enforcement enabled)"
    echo "    - comparison_report.md (human-readable)"
    echo "    - metrics.json (machine-readable)"
    echo "  - combined_summary.md (combined summary of both modes)"
else
    echo "Evaluation failed with exit code: \$EXIT_CODE"
fi
echo "=========================================="
echo ""
if [ "${NONINTERACTIVE:-0}" != "1" ]; then
echo "Press Enter to close this window (or detach with Ctrl+B, then D)"
read
fi
EOF
    
    chmod +x "$EVAL_SCRIPT"
    
    # Start tmux session with the evaluation script
    tmux new-session -d -s "$TMUX_SESSION" -x 120 -y 40 "$EVAL_SCRIPT; bash"
    
    log_success "Evaluation started in tmux session '$TMUX_SESSION'"
    echo ""
    log_info "To attach to the session:"
    log_info "  tmux attach -t $TMUX_SESSION"
    echo ""
    log_info "To detach from tmux (keep it running):"
    log_info "  Press Ctrl+B, then press D"
    echo ""
    log_info "To kill the session when done:"
    log_info "  tmux kill-session -t $TMUX_SESSION"
    
    if [ "${NONINTERACTIVE:-0}" != "1" ]; then
    # Ask if user wants to attach now
    read -p "Attach to tmux session now? (Y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        tmux attach -t "$TMUX_SESSION"
    else
        log_info "Session is running in background. Attach later with: tmux attach -t $TMUX_SESSION"
        fi
    else
        log_info "NONINTERACTIVE=1 set; leaving tmux session running in background."
        log_info "Attach later with: tmux attach -t $TMUX_SESSION"
    fi
}

