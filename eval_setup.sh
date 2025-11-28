#!/bin/bash
# Complete HumanEval Rust Evaluation Setup and Execution Script
#
# Main entry point and orchestration script for HumanEval-Rust evaluation setup.
# Sources all modular libraries and coordinates the complete setup and evaluation workflow.
# 
# This script:
# 1) Provisions a reproducible Python + Rust + GPU environment
# 2) Installs the SigilDERG ecosystem and human-eval-rust
# 3) Runs base vs Rust-QLoRA HumanEval-Rust evaluation and writes a comparison report
# 4) Runs both no-policy and policy-enforced HumanEval-Rust passes and writes comparison reports under humaneval_results/
#
# Optimized for Ubuntu 22.04 Jammy
# Defaults optimized for 1×H100 with 26 vCPUs (overridable via CLI flags)
#
# Copyright (c) 2025 Dave Tofflemire, SigilDERG Project
# Version: 1.3.8

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Get script directory for relative path resolution
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source configuration first
source "$SCRIPT_DIR/eval_setup_config.sh"

# Source all library modules in dependency order
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/environment.sh"
source "$SCRIPT_DIR/lib/system_deps.sh"
source "$SCRIPT_DIR/lib/python_env.sh"
source "$SCRIPT_DIR/lib/pytorch.sh"
source "$SCRIPT_DIR/lib/sigilderg.sh"
source "$SCRIPT_DIR/lib/rust.sh"
source "$SCRIPT_DIR/lib/sandbox.sh"
source "$SCRIPT_DIR/lib/cli_tools.sh"
source "$SCRIPT_DIR/lib/evaluation.sh"
source "$SCRIPT_DIR/lib/tmux.sh"

# Main execution
main() {
    echo "=========================================="
    echo "SigilDERG HumanEval Rust Evaluation Setup"
    echo "=========================================="
    echo "Target: Ubuntu 22.04 Jammy"
    echo ""

    if [ "${SKIP_ENV_CHECK:-0}" != "1" ]; then
        check_environment
    else
        log_warning "SKIP_ENV_CHECK=1 set; skipping OS/GPU checks. Results may not be directly comparable to Lambda baseline."
    fi
    
    # Track errors
    ERRORS=()
    WARNINGS=()
    
    # Run setup steps with error tracking
    {
        install_system_deps || ERRORS+=("System dependencies")
    } 2>&1 | tee setup.log
    
    {
        install_pyenv || ERRORS+=("pyenv installation")
    } 2>&1 | tee -a setup.log
    
    {
        install_python || ERRORS+=("Python installation")
    } 2>&1 | tee -a setup.log
    
    {
        setup_venv || ERRORS+=("Virtual environment setup")
    } 2>&1 | tee -a setup.log
    
    {
        install_pytorch || ERRORS+=("PyTorch installation")
    } 2>&1 | tee -a setup.log
    
    {
        install_sigilderg_components || ERRORS+=("SigilDERG components")
    } 2>&1 | tee -a setup.log
    
    {
        install_rust || ERRORS+=("Rust installation (REQUIRED)")
    } 2>&1 | tee -a setup.log
    
    {
        verify_rust_host || ERRORS+=("Rust host verification")
    } 2>&1 | tee -a setup.log
    
    # Firejail-first sandbox verification (capture status manually)
    set +e
    verify_firejail_sandbox 2>&1 | tee -a setup.log
    SANDBOX_CHECK_EXIT=${PIPESTATUS[0]}
    set -e

    case $SANDBOX_CHECK_EXIT in
        $SANDBOX_STATUS_READY)
            : # Firejail ready
            ;;
        $SANDBOX_STATUS_UNSANDBOXED)
            WARNINGS+=("Running without sandbox protection (user confirmed UNSANDBOXED mode)")
            log_warning "Sandbox mode set to 'none'; running UNSANDBOXED."
            ;;
        $SANDBOX_STATUS_INSTALL_FAILED)
            log_error "Firejail installation failed without approval to continue unsandboxed."
            exit 1
            ;;
        $SANDBOX_STATUS_USER_DECLINED)
            log_error "Sandboxing declined; setup halted per user input."
            exit 1
            ;;
        *)
            ERRORS+=("Sandbox verification returned unexpected status")
            ;;
    esac

    if [ -n "${SANDBOX_MODE:-}" ]; then
        log_info "Selected sandbox mode: ${SANDBOX_MODE}"
    else
        log_warning "Sandbox mode not determined; evaluation may run UNSANDBOXED."
    fi
    
    {
        verify_rust_in_sandbox || ERRORS+=("Rust sandbox verification")
    } 2>&1 | tee -a setup.log
    
    {
        check_tmux || WARNINGS+=("tmux check")
    } 2>&1 | tee -a setup.log
    
    # Install GitHub CLI (run directly to allow interactive auth)
    log_info "Installing/checking GitHub CLI..."
    if install_gh 2>&1 | tee -a setup.log; then
        # Configure git credential helper after successful GitHub CLI authentication
        log_info "Configuring git credential helper..."
        git config --global credential.helper store || log_warning "Failed to configure git credential helper"
        log_success "Git credential helper configured"
    else
        WARNINGS+=("GitHub CLI installation/authentication")
    fi
    
    # Install HuggingFace CLI (run directly to allow interactive auth)
    log_info "Installing/checking HuggingFace CLI..."
    if ! install_hf_cli 2>&1 | tee -a setup.log; then
        WARNINGS+=("HuggingFace CLI installation/authentication")
    fi
    
    {
        create_evaluation_script || ERRORS+=("Evaluation script creation")
    } 2>&1 | tee -a setup.log
    
    # Report status
    echo ""
    echo "=========================================="
    echo "Setup Summary"
    echo "=========================================="
    
    if [ ${#ERRORS[@]} -eq 0 ]; then
        log_success "All critical setup steps completed successfully!"
    else
        log_error "The following steps had errors:"
        for err in "${ERRORS[@]}"; do
            log_error "  - $err"
        done
        echo ""
        log_error "Please check setup.log for details"
        exit 1
    fi
    
    if [ ${#WARNINGS[@]} -gt 0 ]; then
        log_warning "The following steps had warnings (non-critical):"
        for warn in "${WARNINGS[@]}"; do
            log_warning "  - $warn"
        done
    fi
    
    echo ""
    log_info "Setup log saved to: setup.log"
    echo ""
    
    if [ "${NONINTERACTIVE:-0}" = "1" ]; then
        log_info "NONINTERACTIVE=1 set; automatically starting evaluation in tmux."
        run_evaluation
    else
    # Ask to run evaluation
    read -p "Run evaluation now? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        run_evaluation
    else
        log_info "To run evaluation later:"
        log_info "  Option 1: Run in tmux (recommended):"
        log_info "    source $VENV_DIR/bin/activate"
        log_info "    tmux new-session -d -s sigilderg-eval 'python $VENV_DIR/evaluate_humaneval.py --output-dir $OUTPUT_DIR; bash'"
        log_info "    tmux attach -t sigilderg-eval"
        log_info ""
        log_info "  Option 2: Run directly:"
        log_info "    source $VENV_DIR/bin/activate"
        log_info "    python $VENV_DIR/evaluate_humaneval.py --output-dir $OUTPUT_DIR"
        log_info ""
        log_info "  Evaluation modes:"
        log_info "    Script runs BOTH policy and non-policy modes automatically"
        log_info "    Results organized in: no-policy/ and policy/ sub-folders"
        log_info "  Optional flags:"
        log_info "    --policy-only        : Run only policy enforcement mode"
        log_info "    --no-policy-only     : Run only no-policy mode"
        log_info "    --sandbox-mode=firejail: Force Firejail sandboxing (default)"
        log_info "    --sandbox-mode=none     : Run UNSANDBOXED (unsafe, requires confirmation)"
        fi
    fi
}

# Run main
main "$@"
