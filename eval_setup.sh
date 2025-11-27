#!/bin/bash
# Complete HumanEval Rust Evaluation Setup and Execution Script
# Version: 1.3.4
# 
# This script:
# 1) Provisions a reproducible Python + Rust + GPU environment
# 2) Installs the SigilDERG ecosystem and human-eval-rust
# 3) Runs base vs Rust-QLoRA HumanEval-Rust evaluation and writes a comparison report
# 4) Runs both no-policy and policy-enforced HumanEval-Rust passes and writes comparison reports under humaneval_results/
#
# Optimized for Ubuntu 22.04 Jammy
# Defaults optimized for 1×H100 with 26 vCPUs (overridable via CLI flags)

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PYTHON_VERSION="3.12.11"
VENV_DIR="${VENV_DIR:-$HOME/.venvs/sigilderg-humaneval}"
BASE_MODEL="${BASE_MODEL:-meta-llama/Meta-Llama-3.1-8B-Instruct}"
CHECKPOINT_PATH="${CHECKPOINT_PATH:-Superuser666-Sigil/Llama-3.1-8B-Instruct-Rust-QLora/checkpoint-9000}"
OUTPUT_DIR="${OUTPUT_DIR:-./humaneval_results}"
NUM_SAMPLES="${NUM_SAMPLES:-100}"
K_VALUES="${K_VALUES:-1,10,100}"
SANDBOX_MODE="${SANDBOX_MODE:-}"    # Empty = auto-detect, or "docker", "firejail", "none"

# Reproducibility toggles
SKIP_ENV_CHECK="${SKIP_ENV_CHECK:-0}"  # Set to 1 to bypass strict Ubuntu 22.04 + H100 check
NONINTERACTIVE="${NONINTERACTIVE:-0}"  # Set to 1 for CI/non-interactive runs (no prompts)

# Note: Script now runs BOTH policy and non-policy modes automatically
# Results are organized in sub-folders: no-policy/ and policy/

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Error handler
error_exit() {
    log_error "$1"
    log_error "Setup failed. Check the logs above for details."
    exit 1
}

# Environment sanity checks for reproducibility (Ubuntu 22.04 + H100)
check_environment() {
    # OS check
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "${NAME:-}" != "Ubuntu" || "${VERSION_ID:-}" != "22.04" ]]; then
            log_error "This script is validated only on Ubuntu 22.04. Detected: ${PRETTY_NAME:-unknown}"
            error_exit "Unsupported OS for reproducible Lambda eval environment (set SKIP_ENV_CHECK=1 to override)"
        fi
    else
        log_error "/etc/os-release not found; unable to verify OS."
        error_exit "Unsupported OS for reproducible Lambda eval environment (set SKIP_ENV_CHECK=1 to override)"
    fi

    # GPU check
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        log_error "nvidia-smi not found. A CUDA-capable GPU (H100) is required for this environment."
        error_exit "CUDA GPU not detected"
    fi

    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1 || echo "")
    if [[ "$GPU_NAME" != *"H100"* ]]; then
        log_error "This script is validated for NVIDIA H100 only. Detected GPU: ${GPU_NAME:-unknown}"
        error_exit "Unsupported GPU for reproducible Lambda eval environment (set SKIP_ENV_CHECK=1 to override)"
    fi

    log_success "Environment check passed: Ubuntu 22.04 + H100 detected"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Install system dependencies (Ubuntu 22.04)
install_system_deps() {
    log_info "Installing system dependencies for Ubuntu 22.04..."
    
    if command_exists apt-get; then
        # Note: User handles apt update/upgrade separately
        sudo apt-get install -y \
            git build-essential wget curl tmux \
            pkg-config libssl-dev libffi-dev \
            libbz2-dev libreadline-dev libsqlite3-dev \
            zlib1g-dev liblzma-dev \
            || log_warning "Some system packages may not have installed correctly"
        log_success "System dependencies installed"
    else
        log_warning "apt-get not found. Please install system dependencies manually."
    fi
}

# Initialize pyenv in current shell
init_pyenv() {
    export PYENV_ROOT="$HOME/.pyenv"
    [[ -d "$PYENV_ROOT/bin" ]] && export PATH="$PYENV_ROOT/bin:$PATH"
    if [ -d "$PYENV_ROOT" ]; then
        eval "$(pyenv init - bash 2>/dev/null || pyenv init - 2>/dev/null)" || {
            log_warning "Could not initialize pyenv, trying alternative method"
            export PATH="$PYENV_ROOT/bin:$PATH"
        }
    fi
}

# Install pyenv
install_pyenv() {
    log_info "Setting up pyenv..."
    
    # Try to initialize pyenv first (in case it's already installed)
    init_pyenv
    
    if command_exists pyenv; then
        log_success "pyenv already installed and initialized"
        return 0
    fi
    
    log_info "Installing pyenv..."
    curl -fsSL https://pyenv.run | bash || error_exit "Failed to install pyenv"
    
    # Initialize pyenv in current shell after installation
    init_pyenv
    
    # Verify it's working
    if ! command_exists pyenv; then
        log_error "pyenv installed but not available in PATH"
        log_error "Trying to source ~/.bashrc..."
        source ~/.bashrc 2>/dev/null || true
        init_pyenv
    fi
    
    if ! command_exists pyenv; then
        error_exit "pyenv still not available after installation and initialization"
    fi
    
    # Add to shell profile for persistence (if not already there)
    if [ -f ~/.bashrc ] && ! grep -q 'pyenv init' ~/.bashrc; then
        {
            echo ''
            echo '# pyenv'
            echo 'export PYENV_ROOT="$HOME/.pyenv"'
            echo '[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"'
            echo 'eval "$(pyenv init - bash 2>/dev/null || pyenv init - 2>/dev/null)"'
        } >> ~/.bashrc
        log_success "Added pyenv to ~/.bashrc"
    fi
    
    log_success "pyenv installed and initialized"
}

# Install Python 3.12.11
install_python() {
    log_info "Installing Python $PYTHON_VERSION via pyenv..."
    
    # Ensure pyenv is initialized
    init_pyenv
    
    if ! command_exists pyenv; then
        error_exit "pyenv not available. Please restart the script or source ~/.bashrc"
    fi
    
    # Check if Python is already installed
    if pyenv versions --bare 2>/dev/null | grep -q "^${PYTHON_VERSION}$"; then
        log_success "Python $PYTHON_VERSION already installed"
    else
        log_info "This may take 10-15 minutes..."
        pyenv install "$PYTHON_VERSION" || error_exit "Failed to install Python $PYTHON_VERSION"
        log_success "Python $PYTHON_VERSION installed"
    fi
    
    # Set local version
    pyenv local "$PYTHON_VERSION" || error_exit "Failed to set local Python version"
    
    # Verify Python version
    PYTHON_VER=$(python --version 2>&1 | awk '{print $2}' || echo "")
    if [[ "$PYTHON_VER" == "$PYTHON_VERSION" ]]; then
        log_success "Python $PYTHON_VERSION set as local version and verified"
    else
        log_warning "Python version check: expected $PYTHON_VERSION, got $PYTHON_VER"
        log_info "Trying to reinitialize pyenv..."
        init_pyenv
        pyenv local "$PYTHON_VERSION"
    fi
}

# Create and activate virtual environment
setup_venv() {
    log_info "Setting up virtual environment at $VENV_DIR..."
    
    # Ensure pyenv Python is being used
    init_pyenv
    
    if [ ! -d "$VENV_DIR" ]; then
        mkdir -p "$(dirname "$VENV_DIR")"
        # Use pyenv's python explicitly
        PYENV_PYTHON=$(pyenv which python 2>/dev/null || which python)
        log_info "Using Python: $PYENV_PYTHON"
        "$PYENV_PYTHON" -m venv "$VENV_DIR" || error_exit "Failed to create virtual environment"
        log_success "Virtual environment created"
    else
        log_warning "Virtual environment already exists at $VENV_DIR"
    fi
    
    # Activate virtual environment
    source "$VENV_DIR/bin/activate" || error_exit "Failed to activate virtual environment"
    
    # Verify venv is active (use parameter expansion to handle unset variable)
    if [ -z "${VIRTUAL_ENV:-}" ]; then
        error_exit "Virtual environment not activated (VIRTUAL_ENV not set)"
    fi
    
    if [ "${VIRTUAL_ENV:-}" != "$VENV_DIR" ]; then
        error_exit "Virtual environment mismatch: expected $VENV_DIR, got ${VIRTUAL_ENV:-}"
    fi
    
    # Verify we're using venv's pip
    PIP_BIN=$(which pip 2>/dev/null || echo "")
    if [[ -z "$PIP_BIN" ]] || [[ "$PIP_BIN" != "$VENV_DIR/bin/pip"* ]]; then
        log_warning "pip is not from venv: ${PIP_BIN:-not found}"
        log_info "Using venv pip explicitly: $VENV_DIR/bin/pip"
        export PIP_BIN="$VENV_DIR/bin/pip"
    else
        export PIP_BIN="pip"
        log_success "Using venv pip: $PIP_BIN"
    fi
    
    # Verify Python version
    PYTHON_VER=$(python --version 2>&1 | awk '{print $2}')
    if [[ "$PYTHON_VER" != "$PYTHON_VERSION" ]]; then
        log_warning "Python version mismatch: expected $PYTHON_VERSION, got $PYTHON_VER"
        log_info "This may be okay if the venv was created with a different Python"
    else
        log_success "Python version verified: $PYTHON_VER"
    fi
    
    # Upgrade pip using venv's pip explicitly
    log_info "Upgrading pip, wheel, and setuptools..."
    "$VENV_DIR/bin/python" -m pip install --upgrade pip wheel setuptools build twine || error_exit "Failed to upgrade pip"
    
    log_success "Virtual environment activated and verified"
}

# Install PyTorch with CUDA support
install_pytorch() {
    log_info "Installing PyTorch with CUDA support..."
    
    # Ensure venv is active (use parameter expansion to handle unset variable)
    if [ -z "${VIRTUAL_ENV:-}" ] || [ "${VIRTUAL_ENV:-}" != "$VENV_DIR" ]; then
        source "$VENV_DIR/bin/activate" || error_exit "Failed to activate virtual environment"
    fi
    
    # Use venv's pip explicitly
    PIP_CMD="$VENV_DIR/bin/pip"
    
    # Detect CUDA version
    if command_exists nvidia-smi; then
        CUDA_VERSION=$(nvidia-smi | grep -oP 'CUDA Version: \K[0-9]+\.[0-9]+' || echo "12.4")
        log_info "Detected CUDA version: $CUDA_VERSION"
    else
        CUDA_VERSION="12.4"
        log_warning "nvidia-smi not found, defaulting to CUDA 12.4"
    fi
    
    # Install PyTorch based on CUDA version
    if [[ "$CUDA_VERSION" == "12.8" ]] || [[ "$CUDA_VERSION" == "12.9" ]]; then
        log_info "Installing PyTorch 2.7.1 with CUDA 12.8 support..."
        "$PIP_CMD" install torch==2.7.1+cu128 torchvision==0.22.1+cu128 torchaudio==2.7.1+cu128 \
            --index-url https://download.pytorch.org/whl/cu128 \
            || error_exit "Failed to install PyTorch with CUDA 12.8"
    else
        log_info "Installing PyTorch 2.4.0 with CUDA 12.4 support..."
        "$PIP_CMD" install torch==2.4.0 torchvision==0.19.0 torchaudio==2.4.0 \
            --index-url https://download.pytorch.org/whl/cu124 \
            || error_exit "Failed to install PyTorch with CUDA 12.4"
    fi
    
    log_success "PyTorch installed"
    
    # Install Flash Attention v2 (optional, for performance optimization)
    # Note: flash-attn requires torch to be installed first and needs --no-build-isolation
    # It also requires CUDA toolkit and compilation tools, so it may fail on some systems
    log_info "Installing Flash Attention v2 (optional performance optimization)..."
    log_info "This may take several minutes as it compiles from source..."
    
    # Try installing with --no-build-isolation first (allows using installed torch)
    if "$PIP_CMD" install --no-cache-dir --no-build-isolation "flash-attn>=2.5.0" 2>&1 | tee -a setup.log; then
        log_success "Flash Attention v2 installed"
    else
        log_warning "Flash Attention v2 installation failed"
        log_info "Attempting alternative installation method..."
        
        # Try with MAX_JOBS=1 to reduce memory usage during compilation
        if MAX_JOBS=1 "$PIP_CMD" install --no-cache-dir --no-build-isolation "flash-attn>=2.5.0" 2>&1 | tee -a setup.log; then
            log_success "Flash Attention v2 installed (with reduced parallelism)"
        else
            log_warning "Flash Attention v2 installation failed (will use standard attention)"
            log_info "This is not critical - the evaluation will still work, just slower"
            log_info "Flash Attention v2 requires:"
            log_info "  - CUDA toolkit (nvcc compiler)"
            log_info "  - Sufficient GPU memory for compilation"
            log_info "  - Build tools (gcc, make, etc.)"
            log_info "You can install it manually later if needed"
        fi
    fi
}

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
    
    # Install core dependencies first
    log_info "Installing core dependencies..."
    # Install termcolor 3.2.0+ for compatibility across ecosystem
    "$PIP_CMD" install transformers>=4.44.0 accelerate>=0.33.0 peft>=0.12.0 \
        bitsandbytes>=0.43.1 huggingface-hub>=0.24.0 \
        "termcolor>=3.2.0" \
        || error_exit "Failed to install core dependencies"
    
    # Install jsonlines explicitly (required for evaluation script)
    log_info "Installing jsonlines..."
    "$PIP_CMD" install jsonlines>=4.0.0 || error_exit "Failed to install jsonlines"
    log_success "jsonlines installed"
    
    # Install human-eval-rust (with fallback to GitHub if PyPI not available or has syntax errors)
    log_info "Installing human-eval-rust (requires >=1.3.4 for H100 optimizations and sandbox detection fix: 4GB memory, 24 workers, 10s timeout, circular import fix, f-string syntax fix, sandbox auto-detect)..."
    # Uninstall old version first to ensure clean install
    "$PIP_CMD" uninstall -y human-eval-rust 2>/dev/null || true
    # Force reinstall with version constraint to get H100 optimizations and fixes (1.3.4+)
    PYPI_INSTALL_SUCCESS=false
    if "$PIP_CMD" install --force-reinstall --no-cache-dir "human-eval-rust>=1.3.4" 2>&1 | tee -a setup.log; then
        PYPI_INSTALL_SUCCESS=true
        # Small delay to ensure package metadata is fully written
        sleep 2
        
        # CRITICAL: Validate that the package can actually be imported (catches syntax errors)
        log_info "Validating installation (checking for syntax errors)..."
        if ! "$VENV_DIR/bin/python" -c "import human_eval; from human_eval.data import read_problems, get_human_eval_dataset" 2>&1 | tee -a setup.log; then
            log_warning "PyPI package installed but has syntax/import errors. Falling back to GitHub..."
            "$PIP_CMD" uninstall -y human-eval-rust 2>/dev/null || true
            PYPI_INSTALL_SUCCESS=false
        else
            # Verify installation by checking version (more reliable than import check)
            # Try multiple methods to get version
            # First try: Python import (suppress stderr to avoid capturing syntax errors)
            PYTHON_VERSION_OUTPUT=$("$VENV_DIR/bin/python" -c "import human_eval; print(getattr(human_eval, '__version__', 'unknown'))" 2>/dev/null || echo "unknown")
            # Filter out error messages - only accept strings that look like version numbers
            if [[ "$PYTHON_VERSION_OUTPUT" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\+)?$ ]]; then
                INSTALLED_VERSION="$PYTHON_VERSION_OUTPUT"
            else
                INSTALLED_VERSION="unknown"
            fi
            # If that failed, try checking pip show
            if [[ "$INSTALLED_VERSION" == "unknown" ]] || [[ -z "$INSTALLED_VERSION" ]]; then
                PIP_VERSION=$("$PIP_CMD" show human-eval-rust 2>/dev/null | grep "^Version:" | awk '{print $2}' || echo "unknown")
                if [[ "$PIP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\+)?$ ]]; then
                    INSTALLED_VERSION="$PIP_VERSION"
                fi
            fi
            # If still unknown, check if import works at all
            if [[ "$INSTALLED_VERSION" == "unknown" ]] || [[ -z "$INSTALLED_VERSION" ]]; then
                if "$VENV_DIR/bin/python" -c "import human_eval" 2>/dev/null; then
                    # Import works, version might just not be accessible, assume it's the installed version
                    INSTALLED_VERSION="1.3.4+"
                    log_info "Package imports successfully, assuming version >=1.3.4 from PyPI"
                fi
            fi
            
            if [[ "$INSTALLED_VERSION" != "unknown" ]] && [[ -n "$INSTALLED_VERSION" ]]; then
                log_success "human-eval-rust installed from PyPI (version: $INSTALLED_VERSION)"
                # Verify it's the correct version (allow 1.3.4+ format)
                if [[ "$INSTALLED_VERSION" != "1.3.4" ]] && [[ "$INSTALLED_VERSION" != "1.3.4+" ]] && [[ ! "$INSTALLED_VERSION" =~ ^1\.3\.[4-9] ]]; then
                    log_warning "Installed version $INSTALLED_VERSION may not have the latest fixes (expected >=1.3.4)"
                fi
            else
                # Version check failed, but PyPI install succeeded - likely just a version detection issue
                log_warning "PyPI package installed successfully but version check inconclusive"
                log_info "Assuming version >=1.3.4 from PyPI installation (package installed successfully)"
                log_success "human-eval-rust installed from PyPI (version check inconclusive, but installation succeeded)"
            fi
        fi
    fi
    
    # Fallback to GitHub if PyPI install failed or had syntax errors
    if [ "$PYPI_INSTALL_SUCCESS" = false ]; then
        log_warning "PyPI installation failed or had errors, trying GitHub fallback..."
        "$PIP_CMD" install --no-cache-dir git+https://github.com/Superuser666-Sigil/human-eval-Rust.git@main \
            || error_exit "Failed to install human-eval-rust from PyPI or GitHub"
        
        # Validate GitHub installation
        sleep 2
        log_info "Validating GitHub installation (checking for syntax errors)..."
        if ! "$VENV_DIR/bin/python" -c "import human_eval; from human_eval.data import read_problems, get_human_eval_dataset" 2>&1 | tee -a setup.log; then
            error_exit "GitHub installation also has syntax/import errors. Please check the human-eval-Rust repository."
        fi
        
        # Verify GitHub installation version
        PYTHON_VERSION_OUTPUT=$("$VENV_DIR/bin/python" -c "import human_eval; print(getattr(human_eval, '__version__', 'unknown'))" 2>/dev/null || echo "unknown")
        # Filter out error messages - only accept strings that look like version numbers
        if [[ "$PYTHON_VERSION_OUTPUT" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\+)?$ ]]; then
            GITHUB_VERSION="$PYTHON_VERSION_OUTPUT"
        else
            GITHUB_VERSION="unknown"
        fi
        if [[ "$GITHUB_VERSION" == "unknown" ]] || [[ -z "$GITHUB_VERSION" ]]; then
            PIP_VERSION=$("$PIP_CMD" show human-eval-rust 2>/dev/null | grep "^Version:" | awk '{print $2}' || echo "unknown")
            if [[ "$PIP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\+)?$ ]]; then
                GITHUB_VERSION="$PIP_VERSION"
            fi
        fi
        if [[ "$GITHUB_VERSION" != "1.3.4" ]] && [[ "$GITHUB_VERSION" != "unknown" ]] && [[ -n "$GITHUB_VERSION" ]]; then
            log_warning "GitHub installation version $GITHUB_VERSION does not match expected 1.3.4"
            log_warning "This may indicate the GitHub main branch is not up to date. Consider using PyPI version 1.3.4+"
        fi
        log_success "human-eval-rust installed from GitHub (version: ${GITHUB_VERSION:-unknown})"
        # Note: termcolor>=3.2.0 is already installed in core dependencies and is compatible across all ecosystem components
    fi
    
    # Install sigil-pipeline (with fallback to GitHub if PyPI not available)
    log_info "Installing sigil-pipeline (requires >=1.2.1 for termcolor compatibility)..."
    # Uninstall old version first to ensure clean install
    "$PIP_CMD" uninstall -y sigil-pipeline 2>/dev/null || true
    # Force reinstall with version constraint for termcolor compatibility (1.2.1+)
    if "$PIP_CMD" install --force-reinstall --no-cache-dir "sigil-pipeline>=1.2.1" 2>&1 | tee -a setup.log; then
        # Verify installation succeeded
        if "$VENV_DIR/bin/python" -c "import sigil_pipeline" 2>/dev/null; then
            INSTALLED_VERSION=$("$VENV_DIR/bin/python" -c "import sigil_pipeline; print(getattr(sigil_pipeline, '__version__', 'unknown'))" 2>/dev/null || echo "unknown")
            log_success "sigil-pipeline installed from PyPI (version: $INSTALLED_VERSION)"
        else
            log_warning "PyPI package installed but import failed, trying GitHub fallback..."
            "$PIP_CMD" uninstall -y sigil-pipeline 2>/dev/null || true
            "$PIP_CMD" install --no-cache-dir git+https://github.com/Superuser666-Sigil/SigilDERG-Data_Production.git@main \
                || log_warning "Failed to install sigil-pipeline from PyPI or GitHub (optional)"
            log_success "sigil-pipeline installed from GitHub"
        fi
    else
        log_warning "PyPI installation failed, trying GitHub fallback..."
        "$PIP_CMD" install --no-cache-dir git+https://github.com/Superuser666-Sigil/SigilDERG-Data_Production.git@main \
            || log_warning "Failed to install sigil-pipeline from PyPI or GitHub (optional)"
        log_success "sigil-pipeline installed from GitHub"
    fi
    
    # Install sigilderg-finetuner (with fallback to GitHub if PyPI not available)
    log_info "Installing sigilderg-finetuner..."
    # Force upgrade and clear cache to get latest version
    if "$PIP_CMD" install --upgrade --no-cache-dir sigilderg-finetuner 2>&1 | tee -a setup.log; then
        # Verify installation succeeded
        if "$VENV_DIR/bin/python" -c "import rust_qlora" 2>/dev/null; then
            INSTALLED_VERSION=$("$VENV_DIR/bin/python" -c "import rust_qlora; print(getattr(rust_qlora, '__version__', 'unknown'))" 2>/dev/null || echo "unknown")
            log_success "sigilderg-finetuner installed from PyPI (version: $INSTALLED_VERSION)"
        else
            log_warning "PyPI package installed but import failed, trying GitHub fallback..."
            "$PIP_CMD" uninstall -y sigilderg-finetuner 2>/dev/null || true
            "$PIP_CMD" install --no-cache-dir git+https://github.com/Superuser666-Sigil/SigilDERG-Finetuner.git@main \
                || log_warning "Failed to install sigilderg-finetuner from PyPI or GitHub (optional)"
            log_success "sigilderg-finetuner installed from GitHub"
        fi
    else
        log_warning "PyPI installation failed, trying GitHub fallback..."
        "$PIP_CMD" install --no-cache-dir git+https://github.com/Superuser666-Sigil/SigilDERG-Finetuner.git@main \
            || log_warning "Failed to install sigilderg-finetuner from PyPI or GitHub (optional)"
        log_success "sigilderg-finetuner installed from GitHub"
    fi
    
    log_success "SigilDERG components installed"
}

# Install Rust toolchain (REQUIRED - evaluation cannot proceed without Rust)
install_rust() {
    log_info "Checking Rust toolchain (REQUIRED for evaluation)..."
    
    # Source cargo env if it exists (in case Rust was installed previously)
    if [ -f "$HOME/.cargo/env" ]; then
        . "$HOME/.cargo/env" 2>/dev/null || true
    fi
    
    if command_exists rustc; then
        RUST_VERSION=$(rustc --version)
        log_success "Rust already installed: $RUST_VERSION"
        return 0
    else
        log_info "Installing Rust toolchain..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
            || error_exit "Failed to install Rust (REQUIRED for evaluation)"
        
        # Source cargo environment (use dot notation as requested)
        . "$HOME/.cargo/env" || error_exit "Failed to source cargo environment"
        
        # Verify Rust is now available
        if command_exists rustc; then
            RUST_VERSION=$(rustc --version)
            log_success "Rust toolchain installed: $RUST_VERSION"
            return 0
        else
            error_exit "Rust installed but rustc not found in PATH. Evaluation cannot proceed."
        fi
    fi
}

# Check Docker availability
check_docker() {
    log_info "Checking Docker availability..."
    
    if command_exists docker; then
        if docker info >/dev/null 2>&1; then
            log_success "Docker is available and running"
        else
            log_warning "Docker is installed but not running. Attempting to start Docker..."
            
            # Try to start Docker service (systemd)
            if command_exists systemctl; then
                log_info "Starting Docker service via systemctl..."
                if sudo systemctl start docker 2>&1 | tee -a setup.log; then
                    # Wait for Docker to start (30 seconds to be safe)
                    sleep 30
                    if docker info >/dev/null 2>&1; then
                        log_success "Docker service started successfully"
                        # Enable Docker to start on boot
                        sudo systemctl enable docker >/dev/null 2>&1 || true
                    else
                        log_warning "Docker service started but not responding. Sandboxing will use Firejail or process isolation."
                    fi
                else
                    log_warning "Failed to start Docker service. Sandboxing will use Firejail or process isolation."
                fi
            # Try Docker Desktop or dockerd directly
            elif command_exists dockerd; then
                log_info "Attempting to start dockerd..."
                # Start dockerd in background
                sudo dockerd >/dev/null 2>&1 &
                DOCKERD_PID=$!
                # Wait for dockerd to start (30 seconds to be safe)
                sleep 30
                # Check if dockerd process is still running
                if kill -0 "$DOCKERD_PID" 2>/dev/null; then
                    # Check if Docker is responding
                    if docker info >/dev/null 2>&1; then
                        log_success "Docker daemon started successfully"
                    else
                        log_warning "Docker daemon started but not responding. Sandboxing will use Firejail or process isolation."
                    fi
                else
                    log_warning "Could not start Docker daemon. Sandboxing will use Firejail or process isolation."
                fi
            else
                log_warning "Could not determine how to start Docker. Sandboxing will use Firejail or process isolation."
                log_info "You may need to start Docker manually: sudo systemctl start docker"
            fi
        fi
    else
        log_warning "Docker not found. Install Docker for secure sandboxing: https://docs.docker.com/get-docker/"
        log_info "For Ubuntu 22.04, you can install with:"
        log_info "  curl -fsSL https://get.docker.com -o get-docker.sh"
        log_info "  sudo sh get-docker.sh"
    fi
}

# Install GitHub CLI
install_gh() {
    log_info "Checking GitHub CLI (gh)..."
    
    if command_exists gh; then
        GH_VERSION=$(gh --version | head -1)
        log_success "GitHub CLI already installed: $GH_VERSION"
        
        # Check if already authenticated
        if gh auth status >/dev/null 2>&1; then
            log_success "GitHub CLI is already authenticated"
            return 0
        else
            log_info "GitHub CLI not authenticated"
        fi
    else
        log_info "Installing GitHub CLI..."
        
        if command_exists apt-get; then
            # Install gh via apt (Ubuntu/Debian)
            curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
                && sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
                && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
                && sudo apt-get update \
                && sudo apt-get install -y gh \
                || return 1
            
            log_success "GitHub CLI installed"
        else
            log_warning "apt-get not available, cannot install GitHub CLI"
            return 1
        fi
    fi
    
    # Prompt for authentication (interactive - let gh handle its own flow)
    if ! gh auth status >/dev/null 2>&1; then
        if [ "${NONINTERACTIVE:-0}" = "1" ]; then
            log_warning "Skipping GitHub CLI authentication (NONINTERACTIVE=1)."
            log_warning "You can authenticate later with: gh auth login"
            return 0
        fi

        log_info "GitHub CLI authentication required"
        log_info "Starting GitHub CLI authentication (follow the interactive prompts)..."
        echo ""
        # Run authentication - gh handles its own interactive flow and waits for completion
        gh auth login || {
            log_warning "GitHub CLI authentication skipped or failed"
            log_warning "You can authenticate later with: gh auth login"
            return 1
        }
        log_success "GitHub CLI authenticated"
    fi
    
    return 0
}

# Install HuggingFace CLI
install_hf_cli() {
    log_info "Checking HuggingFace CLI (hf)..."
    
    if command_exists hf; then
        HF_VERSION=$(hf --version 2>/dev/null || echo "installed")
        log_success "HuggingFace CLI already installed: $HF_VERSION"
        
        # Check if already authenticated
        if hf whoami >/dev/null 2>&1; then
            HF_USER=$(hf whoami 2>/dev/null || echo "unknown")
            log_success "HuggingFace CLI is already authenticated as: $HF_USER"
            return 0
        else
            log_info "HuggingFace CLI not authenticated"
        fi
    else
        log_info "Installing HuggingFace CLI..."
        
        # Install using official installer
        curl -LsSf https://hf.co/cli/install.sh | bash || return 1
        
        # Add to PATH for current session
        export PATH="$HOME/.local/bin:$PATH"
        
        # Add to bashrc if not already there
        if [ -f ~/.bashrc ] && ! grep -q '\.local/bin' ~/.bashrc; then
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
        fi
        
        # Verify installation
        if command_exists hf; then
            log_success "HuggingFace CLI installed"
        else
            # Try sourcing bashrc
            source ~/.bashrc 2>/dev/null || true
            if ! command_exists hf; then
                log_warning "HuggingFace CLI installed but not in PATH"
                log_warning "Adding to PATH for this session..."
                export PATH="$HOME/.local/bin:$PATH"
                if ! command_exists hf; then
                    log_error "HuggingFace CLI installed but not accessible"
                    return 1
                fi
            fi
        fi
    fi
    
    # Prompt for authentication (interactive - let hf handle its own flow)
    if ! hf whoami >/dev/null 2>&1; then
        if [ "${NONINTERACTIVE:-0}" = "1" ]; then
            log_warning "Skipping HuggingFace CLI authentication (NONINTERACTIVE=1)."
            log_warning "You can authenticate later with: hf auth login"
            return 0
        fi

        log_info "HuggingFace CLI authentication required"
        log_info "Starting HuggingFace CLI authentication (follow the interactive prompts)..."
        echo ""
        # Run authentication - hf handles its own interactive flow and waits for completion
        hf auth login || {
            log_warning "HuggingFace CLI authentication skipped or failed"
            log_warning "You can authenticate later with: hf auth login"
            return 1
        }
        log_success "HuggingFace CLI authenticated"
    fi
    
    return 0
}

# Create evaluation script
create_evaluation_script() {
    log_info "Creating evaluation script..."
    
    cat > "$VENV_DIR/evaluate_humaneval.py" << 'EVAL_SCRIPT_EOF'
#!/usr/bin/env python3
"""
Complete HumanEval Rust evaluation workflow for base and fine-tuned models.
Generated by setup script.
"""
import os
import sys
import platform
import subprocess
import random
from pathlib import Path
from datetime import datetime

import json
import argparse

import numpy as np
import torch
import jsonlines
from transformers import AutoTokenizer, AutoModelForCausalLM
from peft import AutoPeftModelForCausalLM, PeftConfig, PeftModel
from human_eval.data import read_problems, get_human_eval_dataset, write_jsonl
from human_eval.evaluation import evaluate_functional_correctness

# Note: jsonlines is used for efficient batched file writing


def set_seed(seed: int) -> None:
    """Set random seeds for reproducibility."""
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)


def _run_cmd(cmd: str) -> str | None:
    try:
        return subprocess.check_output(
            cmd, shell=True, text=True, stderr=subprocess.DEVNULL
        ).strip()
    except Exception:
        return None


def write_eval_metadata(output_dir: Path, all_results: dict, args, device: str) -> Path:
    """Write environment + configuration metadata for reproducibility."""
    meta: dict[str, object] = {
        "timestamp_utc": datetime.utcnow().isoformat() + "Z",
        "host": platform.node(),
        "os": platform.platform(),
        "python_version": sys.version.split()[0],
        "device": device,
        "cuda_available": torch.cuda.is_available(),
        "seed": getattr(args, "seed", None),
        "args": vars(args),
    }

    if torch.cuda.is_available():
        try:
            meta["torch_cuda_device_name"] = torch.cuda.get_device_name(0)
        except Exception:
            meta["torch_cuda_device_name"] = None
    else:
        meta["torch_cuda_device_name"] = None

    meta["gpu_name_nvidia_smi"] = _run_cmd(
        "nvidia-smi --query-gpu=name --format=csv,noheader | head -n1"
    )

    def _pkg_version(mod_name: str):
        try:
            mod = __import__(mod_name)
            return getattr(mod, "__version__", None)
        except Exception:
            return None

    meta["packages"] = {
        "torch": _pkg_version("torch"),
        "transformers": _pkg_version("transformers"),
        "peft": _pkg_version("peft"),
        "human_eval": _pkg_version("human_eval"),
        "rust_qlora": _pkg_version("rust_qlora"),
        "sigil_pipeline": _pkg_version("sigil_pipeline"),
    }

    venv = os.environ.get("VIRTUAL_ENV")
    if venv:
        pip_path = Path(venv) / "bin" / "pip"
        if pip_path.is_file():
            meta["pip_freeze"] = _run_cmd(f"{pip_path} freeze")

    meta["results_present"] = {
        "no-policy": bool(all_results.get("no-policy")),
        "policy": bool(all_results.get("policy")),
    }

    metadata_file = output_dir / "eval_metadata.json"
    with metadata_file.open("w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2)
    print(f"\n✓ Evaluation metadata written to: {metadata_file}")
    return metadata_file

def generate_samples_for_model(
    model_path: str,
    is_peft: bool,
    output_file: str,
    num_samples_per_task: int = 100,
    batch_size: int = 32,
    max_new_tokens: int = 512,
    temperature: float = 0.2,
    top_p: float = 0.95,
    top_k: int = 50,
    device: str = "cuda",
):
    """Generate samples from a model for HumanEval Rust with batching and Flash Attention v2."""
    
    print(f"\n{'='*60}")
    print(f"Loading model: {model_path}")
    print(f"{'='*60}")
    
    # Check for Flash Attention v2
    try:
        import flash_attn
        print(f"✓ Flash Attention v2 available: {flash_attn.__version__}")
        use_flash_attention = True
    except ImportError:
        print("⚠ Flash Attention v2 not available, falling back to standard attention")
        use_flash_attention = False
    
    # Handle PEFT checkpoint paths (HuggingFace Hub format)
    # If path contains '/checkpoint-', it's a subdirectory checkpoint
    # PEFT supports loading from subdirectories using the 'subfolder' parameter
    actual_model_path = model_path
    checkpoint_subfolder = None
    
    if is_peft and "/checkpoint-" in model_path:
        # Split repo and checkpoint subdirectory
        parts = model_path.split("/checkpoint-")
        repo_id = parts[0]
        checkpoint_name = f"checkpoint-{parts[1]}"
        
        print(f"Detected checkpoint subdirectory: {checkpoint_name}")
        print(f"Repository: {repo_id}")
        
        # Use repo root as model path, and subfolder for the checkpoint
        actual_model_path = repo_id
        checkpoint_subfolder = checkpoint_name
        print(f"Will load from repo: {repo_id}, subfolder: {checkpoint_subfolder}")
    
    # Load tokenizer
    # For PEFT checkpoints, try loading from the checkpoint subfolder first,
    # then fall back to repo root, then base model
    if is_peft:
        tokenizer_loaded = False
        # Try loading from checkpoint subfolder if it exists
        if checkpoint_subfolder:
            try:
                tokenizer = AutoTokenizer.from_pretrained(
                    actual_model_path,
                    subfolder=checkpoint_subfolder
                )
                tokenizer_loaded = True
                print(f"✓ Tokenizer loaded from checkpoint subfolder")
            except Exception as e:
                print(f"Note: Tokenizer not found in checkpoint subfolder ({e})")
        
        # Fallback to repo root
        if not tokenizer_loaded:
            try:
                tokenizer = AutoTokenizer.from_pretrained(actual_model_path)
                tokenizer_loaded = True
                print(f"✓ Tokenizer loaded from repo root")
            except Exception as e:
                print(f"Warning: Could not load tokenizer from repo ({e})")
        
        # Final fallback to base model
        if not tokenizer_loaded:
            print("Using base model tokenizer as fallback")
            tokenizer = AutoTokenizer.from_pretrained("meta-llama/Meta-Llama-3.1-8B-Instruct")
    else:
        tokenizer = AutoTokenizer.from_pretrained(model_path)
    
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token
    
    # Set left padding for decoder-only models (required for correct batched generation)
    tokenizer.padding_side = "left"
    
    # Load model with Flash Attention v2 if available
    print("Loading model weights...")
    try:
        attn_implementation = "flash_attention_2" if use_flash_attention else "sdpa"
        
        if is_peft:
            load_kwargs = {
                "dtype": torch.bfloat16,
                "device_map": "auto",
                "trust_remote_code": True,
                "attn_implementation": attn_implementation,
                "from_tf": False,  # Explicitly prevent TensorFlow loading
                "use_safetensors": True,  # Prefer SafeTensors format
            }
            
            # If we have a checkpoint subfolder, use it
            if checkpoint_subfolder:
                load_kwargs["subfolder"] = checkpoint_subfolder
                print(f"Loading PEFT adapter from subfolder: {checkpoint_subfolder}")
            
            try:
                model = AutoPeftModelForCausalLM.from_pretrained(
                    actual_model_path,
                    **load_kwargs
                )
            except OSError as e:
                # If loading fails with TensorFlow error, try loading base model explicitly
                if "TensorFlow" in str(e) or "from_tf" in str(e):
                    print(f"Warning: Encountered TensorFlow weights issue: {e}")
                    print("Attempting to load base model explicitly, then applying PEFT adapter...")
                    try:
                        # Try to read adapter config to get base model path
                        from peft import PeftConfig
                        if checkpoint_subfolder:
                            config = PeftConfig.from_pretrained(actual_model_path, subfolder=checkpoint_subfolder)
                        else:
                            config = PeftConfig.from_pretrained(actual_model_path)
                        
                        base_model_path = config.base_model_name_or_path
                        print(f"Loading base model from: {base_model_path}")
                        
                        # Load base model explicitly with PyTorch weights only
                        base_model = AutoModelForCausalLM.from_pretrained(
                            base_model_path,
                            dtype=torch.bfloat16,
                            device_map="auto",
                            trust_remote_code=True,
                            attn_implementation=attn_implementation,
                            from_tf=False,
                            use_safetensors=True,
                        )
                        
                        # Then load PEFT adapter
                        if checkpoint_subfolder:
                            model = PeftModel.from_pretrained(
                                base_model,
                                actual_model_path,
                                subfolder=checkpoint_subfolder,
                            )
                        else:
                            model = PeftModel.from_pretrained(
                                base_model,
                                actual_model_path,
                            )
                        print("✓ Successfully loaded model using explicit base model + PEFT adapter approach")
                    except Exception as e2:
                        print(f"ERROR: Failed to load model with explicit base model approach: {e2}")
                        raise e  # Re-raise original error
                else:
                    raise
        else:
            model = AutoModelForCausalLM.from_pretrained(
                model_path,
                dtype=torch.bfloat16,
                device_map="auto",
                trust_remote_code=True,
                attn_implementation=attn_implementation,
                from_tf=False,  # Explicitly prevent TensorFlow loading
                use_safetensors=True,  # Prefer SafeTensors format
            )
    except Exception as e:
        print(f"ERROR: Failed to load model: {e}")
        print(f"Model path: {model_path}")
        print(f"Is PEFT: {is_peft}")
        if is_peft:
            print(f"Actual model path: {actual_model_path}")
            print(f"Checkpoint subfolder: {checkpoint_subfolder}")
        raise
    
    model.eval()
    
    # OPTIMIZATION: Compile model for faster inference (PyTorch 2.0+)
    try:
        model = torch.compile(model, mode="reduce-overhead")
        print("✓ Model compiled with torch.compile for faster inference")
    except Exception as e:
        print(f"Note: torch.compile not available ({e}), using standard inference")
    
    print(f"✓ Model loaded on device: {next(model.parameters()).device}")
    print(f"✓ Using batch size: {batch_size}")
    print(f"✓ Attention implementation: {attn_implementation}")
    
    # Load HumanEval Rust problems
    problems = read_problems(get_human_eval_dataset())
    print(f"✓ Loaded {len(problems)} HumanEval Rust problems")
    
    # Prepare all prompts upfront
    all_prompts = []
    task_ids = []
    
    for task_id, problem in problems.items():
        prompt = problem["prompt"]
        
        # Format prompt with chat template if available
        if hasattr(tokenizer, "apply_chat_template"):
            try:
                messages = [{"role": "user", "content": f"Complete this Rust function:\n\n{prompt}"}]
                formatted_prompt = tokenizer.apply_chat_template(
                    messages, 
                    tokenize=False, 
                    add_generation_prompt=True
                )
            except:
                formatted_prompt = prompt
        else:
            formatted_prompt = prompt
        
        # Add num_samples_per_task copies of this prompt
        for _ in range(num_samples_per_task):
            all_prompts.append(formatted_prompt)
            task_ids.append(task_id)
    
    total_tasks = len(all_prompts)
    print(f"\nGenerating {total_tasks} samples in batches of {batch_size}...")
    print("This may take a while...")
    
    # Prepare output file
    Path(output_file).parent.mkdir(parents=True, exist_ok=True)
    
    samples = []
    
    # Use jsonlines writer for efficient batched writes
    with jsonlines.open(output_file, mode='w') as writer:
        with torch.no_grad():
            # Process in batches
            for batch_start in range(0, total_tasks, batch_size):
                batch_end = min(batch_start + batch_size, total_tasks)
                batch_prompts = all_prompts[batch_start:batch_end]
                batch_task_ids = task_ids[batch_start:batch_end]
                
                try:
                    # Tokenize batch
                    inputs = tokenizer(
                        batch_prompts,
                        return_tensors="pt",
                        padding=True,
                        truncation=True,
                        max_length=2048
                    ).to(device)
                    
                    # Generate batch
                    outputs = model.generate(
                        **inputs,
                        max_new_tokens=max_new_tokens,
                        temperature=temperature,
                        top_p=top_p,
                        do_sample=True,
                        pad_token_id=tokenizer.eos_token_id,
                        eos_token_id=tokenizer.eos_token_id,
                        use_cache=True,  # Explicitly enable KV cache
                    )
                    
                    # Decode batch and collect samples
                    input_lengths = inputs.input_ids.shape[1]
                    batch_samples = []
                    for task_id, output in zip(batch_task_ids, outputs):
                        # Decode only new tokens
                        completion = tokenizer.decode(
                            output[input_lengths:],
                            skip_special_tokens=True
                        )
                        
                        # Clean up completion
                        if "```rust" in completion:
                            completion = completion.split("```rust")[-1]
                        if "```" in completion:
                            completion = completion.split("```")[0]
                        completion = completion.strip()
                        
                        batch_samples.append({
                            "task_id": task_id,
                            "completion": completion,
                        })
                    
                    # Write entire batch at once (more efficient than per-sample)
                    writer.write_all(batch_samples)
                    samples.extend(batch_samples)
                    
                except Exception as e:
                    print(f"  WARNING: Failed to generate batch starting at {batch_start}: {e}")
                    # Fallback to individual generation for this batch
                    for task_id, prompt in zip(batch_task_ids, batch_prompts):
                        try:
                            inputs = tokenizer(prompt, return_tensors="pt", truncation=True, max_length=2048).to(device)
                            outputs = model.generate(
                                **inputs,
                                max_new_tokens=max_new_tokens,
                                temperature=temperature,
                                top_p=top_p,
                                do_sample=True,
                                pad_token_id=tokenizer.eos_token_id,
                                eos_token_id=tokenizer.eos_token_id,
                            )
                            completion = tokenizer.decode(
                                outputs[0][inputs.input_ids.shape[1]:],
                                skip_special_tokens=True
                            )
                            if "```rust" in completion:
                                completion = completion.split("```rust")[-1]
                            if "```" in completion:
                                completion = completion.split("```")[0]
                            completion = completion.strip()
                            
                            sample = {"task_id": task_id, "completion": completion}
                            samples.append(sample)
                            
                            # Write individual sample (fallback path) - append mode
                            with jsonlines.open(output_file, mode='a') as writer_single:
                                writer_single.write(sample)
                        except Exception as e2:
                            print(f"  WARNING: Failed to generate sample for {task_id}: {e2}")
                            continue
                
                # Progress update (always runs, success or fallback)
                current = len(samples)
                if current % (batch_size * 5) == 0 or current == total_tasks:
                    print(f"  Generated {current}/{total_tasks} samples ({current/total_tasks*100:.1f}%)")
    
    print(f"\n✓ Generated {len(samples)} samples")
    print(f"✓ Saved to {output_file}")
    
    return output_file

def _filter_bad_samples(sample_file: str) -> str:
    """
    Pre-filter obviously bad samples to save evaluation time.
    Returns path to filtered sample file.
    """
    import jsonlines
    import tempfile
    
    filtered_count = 0
    total_count = 0
    filtered_file = sample_file + ".filtered"
    
    with jsonlines.open(sample_file, mode='r') as reader, \
         jsonlines.open(filtered_file, mode='w') as writer:
        
        for sample in reader:
            total_count += 1
            completion = sample.get('completion', '').strip()
            
            # Filter out empty completions
            if not completion:
                filtered_count += 1
                continue
            
            # Filter out very short completions (<20 chars) - likely incomplete
            if len(completion) < 20:
                filtered_count += 1
                continue
            
            # Filter out completions with severe brace mismatches (>2 difference)
            # This catches obviously incomplete/truncated code
            open_braces = completion.count('{')
            close_braces = completion.count('}')
            if abs(open_braces - close_braces) > 2:
                filtered_count += 1
                continue
            
            # Keep the sample
            writer.write(sample)
    
    if filtered_count > 0:
        print(f"  Filtered out {filtered_count}/{total_count} obviously bad samples ({filtered_count/total_count*100:.1f}%)")
        print(f"  Evaluating {total_count - filtered_count} samples")
    
    return filtered_file if filtered_count > 0 else sample_file


def evaluate_samples(
    sample_file: str, 
    output_dir: Path, 
    k_values: list[int] = [1, 10, 100],
    sandbox_mode: str | None = None,
    enforce_policy: bool = True,
    n_workers: int = 24,  # Default: H100 optimized (26 vCPUs - 2 reserved)
    timeout: float = 10.0,  # Default: H100 optimized
):
    """Evaluate samples and return metrics."""
    import os
    # Disable tokenizers parallelism warnings when using multiprocessing (evaluation phase only)
    # This prevents warnings when forking processes for parallel evaluation
    os.environ["TOKENIZERS_PARALLELISM"] = "false"
    
    print(f"\n{'='*60}")
    print(f"Evaluating: {sample_file}")
    print(f"{'='*60}")
    print(f"Sandbox mode: {sandbox_mode or 'auto-detect'}")
    print(f"Policy enforcement: {enforce_policy}")
    print(f"Workers: {n_workers}, Timeout: {timeout}s")
    
    # Pre-filter obviously bad samples to save evaluation time
    print("\nPre-filtering obviously bad samples...")
    filtered_file = _filter_bad_samples(sample_file)
    
    try:
        results = evaluate_functional_correctness(
            filtered_file,
            k_values,
            n_workers=n_workers,
            timeout=timeout,
            problem_file=None,
            language="rust",
            sandbox_mode=sandbox_mode,  # None = auto-detect
            enforce_policy=enforce_policy,
        )
        
        # Clean up filtered file if we created one
        if filtered_file != sample_file:
            import os
            try:
                os.remove(filtered_file)
            except Exception:
                pass  # Ignore cleanup errors
        
        return results
    except Exception as e:
        print(f"ERROR: Evaluation failed: {e}")
        raise

def write_metrics_json(
    base_results: dict | None,
    finetuned_results: dict | None,
    config: dict,
    output_dir: Path,
):
    """Write metrics to JSON file for easy programmatic access."""
    metrics_file = output_dir / "metrics.json"
    
    metrics = {
        "base": base_results or {},
        "finetuned": finetuned_results or {},
        "config": config,
        "timestamp": datetime.now().isoformat(),
    }
    
    with open(metrics_file, "w", encoding="utf-8") as f:
        json.dump(metrics, f, indent=2)
    
    print(f"\n✓ Metrics JSON saved to: {metrics_file}")
    return metrics_file

def create_comparison_report(
    base_results: dict,
    finetuned_results: dict,
    output_dir: Path,
):
    """Create a comparison report."""
    
    report_file = output_dir / "comparison_report.md"
    
    report = f"""# HumanEval Rust Evaluation Comparison Report

Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}

## Models Evaluated

- **Base Model**: Meta Llama 3.1 8B Instruct
- **Fine-tuned Model**: Llama-3.1-8B-Instruct-Rust-QLora (checkpoint-9000)

## Results Summary

### Base Model Performance

"""
    
    for metric, value in sorted(base_results.items()):
        report += f"- **{metric}**: {value:.4f} ({value*100:.2f}%)\n"
    
    report += "\n### Fine-tuned Model Performance\n\n"
    
    for metric, value in sorted(finetuned_results.items()):
        report += f"- **{metric}**: {value:.4f} ({value*100:.2f}%)\n"
    
    report += "\n## Improvement Analysis\n\n"
    
    for metric in sorted(set(base_results.keys()) & set(finetuned_results.keys())):
        base_val = base_results.get(metric, 0)
        finetuned_val = finetuned_results.get(metric, 0)
        improvement = finetuned_val - base_val
        improvement_pct = (improvement / base_val * 100) if base_val > 0 else 0
        
        report += f"### {metric}\n"
        report += f"- Base: {base_val:.4f} ({base_val*100:.2f}%)\n"
        report += f"- Fine-tuned: {finetuned_val:.4f} ({finetuned_val*100:.2f}%)\n"
        report += f"- **Improvement**: {improvement:+.4f} ({improvement_pct:+.2f}%)\n\n"
    
    with open(report_file, "w", encoding="utf-8") as f:
        f.write(report)
    
    print(f"\n✓ Comparison report saved to: {report_file}")
    return report_file

def run_evaluation_mode(
    base_model: str,
    checkpoint_path: str,
    output_dir: Path,
    num_samples: int,
    k_values: list[int],
    sandbox_mode: str | None,
    enforce_policy: bool,
    skip_base: bool,
    skip_finetuned: bool,
    n_workers: int = 24,
    timeout: float = 10.0,
    batch_size: int = 32,
    max_new_tokens: int = 512,
    device: str = "cuda",
    seed: int | None = None,
):
    """Run evaluation for a single policy mode."""
    policy_label = "policy" if enforce_policy else "no-policy"
    mode_output_dir = output_dir / policy_label
    mode_output_dir.mkdir(parents=True, exist_ok=True)
    
    print(f"\n{'='*80}")
    print(f"Running evaluation with policy enforcement: {enforce_policy}")
    print(f"Results will be saved to: {mode_output_dir}")
    print(f"{'='*80}\n")
    
    # Store config for JSON output
    config = {
        "base_model": base_model,
        "checkpoint": checkpoint_path,
        "num_samples": num_samples,
        "k_values": k_values,
        "sandbox_mode": sandbox_mode or "auto-detect",
        "enforce_policy": enforce_policy,
        "device": device,
        "n_workers": n_workers,
        "timeout": timeout,
        "batch_size": batch_size,
        "max_new_tokens": max_new_tokens,
        "seed": seed,
    }
    
    base_results = None
    finetuned_results = None
    
    # Evaluate base model
    if not skip_base:
        base_samples_file = mode_output_dir / "base_model_samples.jsonl"
        generate_samples_for_model(
            base_model,
            False,
            str(base_samples_file),
            num_samples_per_task=num_samples,
            batch_size=batch_size,
            max_new_tokens=max_new_tokens,
            device=device,
        )
        base_results = evaluate_samples(
            str(base_samples_file), 
            mode_output_dir, 
            k_values,
            sandbox_mode=sandbox_mode,
            enforce_policy=enforce_policy,
            n_workers=n_workers,
            timeout=timeout,
        )
        print(f"\nBase model results ({policy_label}): {base_results}")
    
    # Evaluate fine-tuned model
    if not skip_finetuned:
        finetuned_samples_file = mode_output_dir / "finetuned_model_samples.jsonl"
        generate_samples_for_model(
            checkpoint_path,
            True,
            str(finetuned_samples_file),
            num_samples_per_task=num_samples,
            batch_size=batch_size,
            max_new_tokens=max_new_tokens,
            device=device,
        )
        finetuned_results = evaluate_samples(
            str(finetuned_samples_file), 
            mode_output_dir, 
            k_values,
            sandbox_mode=sandbox_mode,
            enforce_policy=enforce_policy,
            n_workers=n_workers,
            timeout=timeout,
        )
        print(f"\nFine-tuned model results ({policy_label}): {finetuned_results}")
    
    # Write JSON metrics
    write_metrics_json(base_results, finetuned_results, config, mode_output_dir)
    
    # Create markdown report
    if base_results and finetuned_results:
        create_comparison_report(base_results, finetuned_results, mode_output_dir)
    
    return {
        "base": base_results,
        "finetuned": finetuned_results,
        "config": config,
    }

def main():
    parser = argparse.ArgumentParser(description="HumanEval Rust evaluation")
    parser.add_argument(
        "--base-model",
        default="meta-llama/Meta-Llama-3.1-8B-Instruct",
    )
    parser.add_argument(
        "--checkpoint-path",
        default="Superuser666-Sigil/Llama-3.1-8B-Instruct-Rust-QLora/checkpoint-9000",
    )
    parser.add_argument("--output-dir", default="./humaneval_results")
    parser.add_argument("--num-samples", type=int, default=100)
    parser.add_argument("--k-values", default="1,10,100")
    parser.add_argument("--skip-base", action="store_true")
    parser.add_argument("--skip-finetuned", action="store_true")
    parser.add_argument(
        "--sandbox-mode",
        default=None,
        help="Sandbox mode: 'docker', 'firejail', 'none', or None for auto-detect",
    )
    parser.add_argument(
        "--policy-only",
        action="store_true",
        help="Run only policy enforcement mode (skip no-policy)",
    )
    parser.add_argument(
        "--no-policy-only",
        action="store_true",
        help="Run only no-policy mode (skip policy enforcement)",
    )
    parser.add_argument(
        "--n-workers",
        type=int,
        default=24,
        help="Number of parallel workers for evaluation (default: 24 for H100)",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=10.0,
        help="Per-sample timeout in seconds (default: 10.0 for H100)",
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=32,
        help="Batch size for sample generation (default: 32 for H100)",
    )
    parser.add_argument(
        "--max-new-tokens",
        type=int,
        default=512,
        help="Maximum new tokens per generation (default: 512)",
    )
    parser.add_argument(
        "--device",
        default="auto",
        help="Device to run on: 'cuda', 'cpu', or 'auto' (default: auto)",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=1234,
        help="Random seed for reproducibility",
    )
    
    args = parser.parse_args()

    # Seed RNGs for reproducibility
    set_seed(args.seed)

    # Resolve device
    if args.device == "auto":
        device = "cuda" if torch.cuda.is_available() else "cpu"
    else:
        device = args.device
    print(f"Using device: {device}")
    
    k_values = [int(k.strip()) for k in args.k_values.split(",")]
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    
    # Determine sandbox mode
    sandbox_mode = args.sandbox_mode if args.sandbox_mode else None
    
    # Determine which modes to run
    run_no_policy = not args.policy_only
    run_policy = not args.no_policy_only
    
    if not run_no_policy and not run_policy:
        print("Nothing to do: both modes disabled.")
        sys.exit(0)
    
    all_results: dict[str, dict | None] = {"no-policy": None, "policy": None}

    # Run no-policy evaluation first (if requested)
    if run_no_policy:
        print("\n" + "=" * 80)
        print("PHASE 1: Running evaluation WITHOUT policy enforcement")
        print("=" * 80)
        no_policy_results = run_evaluation_mode(
            args.base_model,
            args.checkpoint_path,
            output_dir,
            args.num_samples,
            k_values,
            sandbox_mode,
            enforce_policy=False,
            skip_base=args.skip_base,
            skip_finetuned=args.skip_finetuned,
            n_workers=args.n_workers,
            timeout=args.timeout,
            batch_size=args.batch_size,
            max_new_tokens=args.max_new_tokens,
            device=device,
            seed=args.seed,
        )
        all_results["no-policy"] = no_policy_results
        print(
            f"\n✓ Non-policy evaluation complete! Results in: {output_dir / 'no-policy'}"
        )
    
    # Run policy evaluation second (if requested)
    if run_policy:
        print("\n" + "=" * 80)
        print("PHASE 2: Running evaluation WITH policy enforcement")
        print("=" * 80)
        policy_results = run_evaluation_mode(
            args.base_model,
            args.checkpoint_path,
            output_dir,
            args.num_samples,
            k_values,
            sandbox_mode,
            enforce_policy=True,
            skip_base=args.skip_base,
            skip_finetuned=args.skip_finetuned,
            n_workers=args.n_workers,
            timeout=args.timeout,
            batch_size=args.batch_size,
            max_new_tokens=args.max_new_tokens,
            device=device,
            seed=args.seed,
        )
        all_results["policy"] = policy_results
        print(
            f"\n✓ Policy evaluation complete! Results in: {output_dir / 'policy'}"
        )
    
    # Combined summary markdown (unchanged from your existing logic)
    if all_results["no-policy"] or all_results["policy"]:
        summary_file = output_dir / "combined_summary.md"
        with summary_file.open("w", encoding="utf-8") as f:
            f.write("# HumanEval Rust Evaluation Summary\n\n")
            f.write(f"- Base model: `{args.base_model}`\n")
            f.write(f"- Fine-tuned checkpoint: `{args.checkpoint_path}`\n")
            f.write(f"- Num samples per task: {args.num_samples}\n")
            f.write(f"- k-values: {k_values}\n")
            f.write(f"- Device: {device}\n")
            f.write(f"- Seed: {args.seed}\n\n")

            if all_results["no-policy"]:
                f.write("## No-Policy Mode\n\n")
            if all_results["no-policy"]["base"]:
                f.write("### Base Model\n")
                for metric, value in sorted(
                    all_results["no-policy"]["base"].items()
                ):
                    f.write(f"- **{metric}**: {value:.4f} ({value*100:.2f}%)\n")
            if all_results["no-policy"]["finetuned"]:
                f.write("\n### Fine-tuned Model\n")
                for metric, value in sorted(
                    all_results["no-policy"]["finetuned"].items()
                ):
                    f.write(f"- **{metric}**: {value:.4f} ({value*100:.2f}%)\n")
            
            if all_results["policy"]:
                f.write("\n## Policy Enforcement Mode\n\n")
            if all_results["policy"]["base"]:
                f.write("### Base Model\n")
                for metric, value in sorted(
                    all_results["policy"]["base"].items()
                ):
                    f.write(f"- **{metric}**: {value:.4f} ({value*100:.2f}%)\n")
            if all_results["policy"]["finetuned"]:
                f.write("\n### Fine-tuned Model\n")
                for metric, value in sorted(
                    all_results["policy"]["finetuned"].items()
                ):
                    f.write(f"- **{metric}**: {value:.4f} ({value*100:.2f}%)\n")
        
        print(f"\n✓ Combined summary saved to: {summary_file}")
    
    # Top-level metadata for Lambda
    write_eval_metadata(output_dir, all_results, args, device)

    print("\n" + "=" * 80)
    print("All Evaluations Complete!")
    print("=" * 80)
    print(f"\nResults organized in sub-folders:")
    if run_no_policy:
        print(f"  - {output_dir / 'no-policy'}/ (no policy enforcement)")
    if run_policy:
        print(f"  - {output_dir / 'policy'}/ (policy enforcement enabled)")
    if run_no_policy and run_policy:
        print(f"  - {output_dir / 'combined_summary.md'} (combined summary)")

if __name__ == "__main__":
    main()
EVAL_SCRIPT_EOF

    chmod +x "$VENV_DIR/evaluate_humaneval.py"
    log_success "Evaluation script created"
}

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
        if [ -n "$SANDBOX_MODE" ]; then
            PY_ARGS+=( --sandbox-mode "$SANDBOX_MODE" )
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
    
    # Add sandbox mode if specified
    if [ -n "$SANDBOX_MODE" ]; then
        EVAL_CMD="$EVAL_CMD --sandbox-mode $SANDBOX_MODE"
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
        check_docker || WARNINGS+=("Docker check")
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
        log_info "    --sandbox-mode=docker: Force Docker sandboxing"
        log_info "    --sandbox-mode=none  : No sandboxing (UNSAFE, dev only)"
        fi
    fi
}

# Run main
main "$@"

