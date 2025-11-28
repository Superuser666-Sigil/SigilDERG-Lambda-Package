#!/bin/bash
# lib/sigilderg.sh
#
# SigilDERG ecosystem component installation.
#
# Installs core dependencies, human-eval-rust, sigil-pipeline, and sigilderg-finetuner
# using unified constraints to prevent dependency conflicts between packages.
#
# Key features:
#   - Uses constraints.txt to ensure compatible versions across ecosystem
#   - Supports pip-tools/uv lockfile generation for reproducible builds
#   - Validates package imports after installation
#   - Falls back to GitHub if PyPI packages have issues
#
# Required minimum versions:
#   - human-eval-rust >= 2.3.0
#   - sigil-pipeline >= 2.3.0
#   - sigilderg-finetuner >= 3.0.0
#
# Copyright (c) 2025 Dave Tofflemire, SigilDERG Project
# Version: 2.5.0

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/eval_setup_config.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/python_env.sh"

# Minimum version requirements for ecosystem components
MIN_HUMAN_EVAL_RUST_VERSION="2.3.0"
MIN_SIGIL_PIPELINE_VERSION="2.3.0"
MIN_SIGILDERG_FINETUNER_VERSION="3.0.0"

# Constraints file for unified dependency management
CONSTRAINTS_FILE="$SCRIPT_DIR/constraints.txt"

# Install SigilDERG components
install_sigilderg_components() {
    log_info "Installing SigilDERG ecosystem components..."
    
    # Ensure venv is active (use parameter expansion to handle unset variable)
    if [ -z "${VIRTUAL_ENV:-}" ] || [ "${VIRTUAL_ENV:-}" != "$VENV_DIR" ]; then
        source "$VENV_DIR/bin/activate" || error_exit "Failed to activate virtual environment"
    fi
    
    # Use venv's pip explicitly
    PIP_CMD="$VENV_DIR/bin/pip"
    
    # Verify pip is using venv
    PIP_LOCATION=$("$PIP_CMD" --version 2>&1 | head -1)
    log_info "Using pip: $PIP_CMD"
    log_info "Pip location: $PIP_LOCATION"
    
    # Check for constraints file
    if [ -f "$CONSTRAINTS_FILE" ]; then
        log_info "Using constraints file: $CONSTRAINTS_FILE"
        CONSTRAINT_OPTS="-c $CONSTRAINTS_FILE"
    else
        log_warning "Constraints file not found at $CONSTRAINTS_FILE"
        log_warning "Installing without constraints may cause dependency conflicts"
        CONSTRAINT_OPTS=""
    fi
    
    # Install pip-tools for lockfile generation (optional but recommended)
    log_info "Installing pip-tools for reproducible builds..."
    "$PIP_CMD" install pip-tools >/dev/null 2>&1 || log_warning "pip-tools installation failed (optional)"
    
    # Install core dependencies first WITH CONSTRAINTS to lock versions
    log_info "Installing core dependencies with unified constraints..."
    # Install termcolor 3.2.0+ for compatibility across ecosystem
    "$PIP_CMD" install $CONSTRAINT_OPTS \
        "transformers>=4.44.0" "accelerate>=0.33.0" "peft>=0.12.0" \
        "bitsandbytes>=0.43.1" "huggingface-hub>=0.24.0" \
        "rich>=13.7.0,<14.0.0" "psutil>=6.1.1,<7.0.0" \
        "termcolor>=3.2.0" \
        || error_exit "Failed to install core dependencies"
    
    # Install jsonlines explicitly (required for evaluation script)
    log_info "Installing jsonlines..."
    "$PIP_CMD" install $CONSTRAINT_OPTS "jsonlines>=4.0.0" || error_exit "Failed to install jsonlines"
    log_success "jsonlines installed"
    
    # Install all SigilDERG ecosystem components together to let pip resolve dependencies
    log_info "Installing SigilDERG ecosystem packages..."
    log_info "  - human-eval-rust >= $MIN_HUMAN_EVAL_RUST_VERSION"
    log_info "  - sigil-pipeline >= $MIN_SIGIL_PIPELINE_VERSION"  
    log_info "  - sigilderg-finetuner >= $MIN_SIGILDERG_FINETUNER_VERSION"
    
    # Uninstall old versions first to ensure clean install
    "$PIP_CMD" uninstall -y human-eval-rust sigil-pipeline sigilderg-finetuner 2>/dev/null || true
    
    # Try to install all packages together with constraints (allows pip to resolve dependencies)
    ECOSYSTEM_INSTALL_SUCCESS=false
    if "$PIP_CMD" install $CONSTRAINT_OPTS --no-cache-dir \
        "human-eval-rust>=${MIN_HUMAN_EVAL_RUST_VERSION}" \
        "sigil-pipeline>=${MIN_SIGIL_PIPELINE_VERSION}" \
        "sigilderg-finetuner>=${MIN_SIGILDERG_FINETUNER_VERSION}" \
        2>&1 | tee -a setup.log; then
        
        # Small delay to ensure package metadata is fully written
        sleep 2
        
        # Validate all packages can be imported
        log_info "Validating ecosystem installation..."
        VALIDATION_FAILED=false
        
        if ! "$VENV_DIR/bin/python" -c "import human_eval; from human_eval.data import read_problems" 2>&1; then
            log_warning "human-eval-rust import validation failed"
            VALIDATION_FAILED=true
        fi
        
        if ! "$VENV_DIR/bin/python" -c "import sigil_pipeline" 2>&1; then
            log_warning "sigil-pipeline import validation failed"
            VALIDATION_FAILED=true
        fi
        
        if ! "$VENV_DIR/bin/python" -c "import rust_qlora" 2>&1; then
            log_warning "sigilderg-finetuner import validation failed"
            VALIDATION_FAILED=true
        fi
        
        if [ "$VALIDATION_FAILED" = false ]; then
            ECOSYSTEM_INSTALL_SUCCESS=true
            log_success "All ecosystem packages installed and validated"
        fi
    fi
    
    # Fallback: Install packages individually from GitHub if unified install failed
    if [ "$ECOSYSTEM_INSTALL_SUCCESS" = false ]; then
        log_warning "Unified ecosystem installation failed, falling back to individual installation..."
        
        # human-eval-rust
        log_info "Installing human-eval-rust from GitHub..."
        "$PIP_CMD" uninstall -y human-eval-rust 2>/dev/null || true
        "$PIP_CMD" install $CONSTRAINT_OPTS --no-cache-dir \
            git+https://github.com/Superuser666-Sigil/human-eval-Rust.git@main \
            || log_warning "human-eval-rust GitHub installation failed"
        
        # sigil-pipeline
        log_info "Installing sigil-pipeline from GitHub..."
        "$PIP_CMD" uninstall -y sigil-pipeline 2>/dev/null || true
        "$PIP_CMD" install $CONSTRAINT_OPTS --no-cache-dir \
            git+https://github.com/Superuser666-Sigil/SigilDERG-Data_Production.git@main \
            || log_warning "sigil-pipeline GitHub installation failed"
        
        # sigilderg-finetuner  
        log_info "Installing sigilderg-finetuner from GitHub..."
        "$PIP_CMD" uninstall -y sigilderg-finetuner 2>/dev/null || true
        "$PIP_CMD" install $CONSTRAINT_OPTS --no-cache-dir \
            git+https://github.com/Superuser666-Sigil/SigilDERG-Finetuner.git@main \
            || log_warning "sigilderg-finetuner GitHub installation failed"
    fi
    
    # Run pip check to verify no dependency conflicts
    log_info "Verifying dependency consistency..."
    if "$PIP_CMD" check 2>&1 | tee -a setup.log; then
        log_success "No dependency conflicts detected"
    else
        log_warning "Dependency conflicts detected - check setup.log for details"
        log_warning "The installation may still work, but some features might be affected"
    fi
    
    # Report installed versions
    log_info "Installed ecosystem versions:"
    HUMAN_EVAL_VERSION=$(_get_package_version "human_eval" "human-eval-rust")
    PIPELINE_VERSION=$(_get_package_version "sigil_pipeline" "sigil-pipeline")
    FINETUNER_VERSION=$(_get_package_version "rust_qlora" "sigilderg-finetuner")
    log_info "  human-eval-rust: ${HUMAN_EVAL_VERSION:-unknown}"
    log_info "  sigil-pipeline: ${PIPELINE_VERSION:-unknown}"
    log_info "  sigilderg-finetuner: ${FINETUNER_VERSION:-unknown}"
    
    log_success "SigilDERG components installed"
}

# Helper function to get package version
_get_package_version() {
    local module_name="$1"
    local pip_name="$2"
    
    # Try Python import first
    local version
    version=$("$VENV_DIR/bin/python" -c "import ${module_name}; print(getattr(${module_name}, '__version__', 'unknown'))" 2>/dev/null || echo "unknown")
    
    # Filter out error messages - only accept strings that look like version numbers
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$version"
        return
    fi
    
    # Fallback to pip show
    version=$("$PIP_CMD" show "$pip_name" 2>/dev/null | grep "^Version:" | awk '{print $2}' || echo "unknown")
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$version"
        return
    fi
    
    echo "unknown"
}
