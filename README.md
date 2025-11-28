# SigilDERG Lambda Package

## Overview

Reproducible HumanEval-Rust evaluation pipeline for SigilDERG ecosystem models.

## Supported Environment

**Tested on:** Lambda Labs H100 SXM5 (80 GB), Ubuntu 22.04, Lambda Stack 22.04
image (`lambda-stack-22-04`).

**System Specifications:**

- GPU: 1× NVIDIA H100 (80 GB SXM5)
- CPU: 26 vCPUs
- RAM: 225 GiB
- Storage: 2.8 TiB SSD

**Note:** The base Lambda Stack 22.04 image ships with Python 3.10, but this
script automatically provisions Python 3.12.11 via pyenv in a dedicated virtual
environment to ensure consistency and compatibility.

## One-Line Usage

```bash
curl -sS \
  https://raw.githubusercontent.com/Superuser666-Sigil/\
SigilDERG-Lambda-Package/main/eval_setup.sh \
  | bash
```

Or clone and run:

```bash
git clone https://github.com/Superuser666-Sigil/SigilDERG-Lambda-Package.git
cd SigilDERG-Lambda-Package
chmod +x eval_setup.sh
./eval_setup.sh
```

## What It Does

The `eval_setup.sh` script is **idempotent, self-checking, and hard-fails on
missing dependencies**. It:

### Provisions Environment

- Installs system dependencies (build tools, libraries, tmux)
- Bootstraps **Python 3.12.11** via pyenv (even though base image has 3.10)
- Creates dedicated virtual environment at `~/.venvs/sigilderg-humaneval`
- Installs **PyTorch 2.4.0** (CUDA 12.4) or **PyTorch 2.7.1** (CUDA 12.8+) with
  Flash Attention v2
- Installs **Rust toolchain** via rustup (required for evaluation)
- Installs/verifies Firejail sandboxing (prompts before running unsandboxed)

### Installs SigilDERG Ecosystem

- **sigil-pipeline** >= 2.1.0 (from PyPI, GitHub fallback)
- **sigilderg-finetuner** >= 2.9.0 (from PyPI, GitHub fallback)
- **human-eval-rust** >= 2.1.0 (from PyPI, GitHub fallback)
- Core ML dependencies (transformers, accelerate, peft, bitsandbytes, etc.)

### Runs Evaluation

- **Base Model:** `meta-llama/Meta-Llama-3.1-8B-Instruct`
  - HumanEval-Rust evaluation (no-policy mode)
  - HumanEval-Rust evaluation (policy-enforced mode)
- **Fine-tuned Model:**
  `Superuser666-Sigil/Llama-3.1-8B-Instruct-Rust-QLora/checkpoint-9000`
  - HumanEval-Rust evaluation (no-policy mode)
  - HumanEval-Rust evaluation (policy-enforced mode)

### Writes Outputs

- `humaneval_results/no-policy/` - No-policy mode results:
  - `base_model_samples.jsonl` - Generated samples from base model
  - `finetuned_model_samples.jsonl` - Generated samples from fine-tuned model
  - `metrics.json` - Machine-readable metrics (pass@1, pass@10, pass@100)
  - `comparison_report.md` - Human-readable comparison report
- `humaneval_results/policy/` - Policy-enforced mode results (same structure)
- `humaneval_results/combined_summary.md` - Combined summary comparing both
  modes
- `humaneval_results/eval_metadata.json` - Complete environment and
  configuration metadata
- `setup.log` - Complete setup and execution log

## Ecosystem Version Guarantees

This package guarantees a consistent, tested combination of ecosystem
components:

| Component | Minimum Version | Purpose |
| --- | --- | --- |
| **sigil-pipeline** | >= 2.1.0 | Rust code dataset generation |
| **sigilderg-finetuner** | >= 2.9.0 | QLoRA fine-tuning on Rust code |
| **human-eval-rust** | >= 2.1.0 | HumanEval-Rust evaluation harness |

**Architecture:** See
[SigilDERG Ecosystem Architecture](https://github.com/Superuser666-Sigil/SigilDERG-Data_Production/blob/main/ARCHITECTURE.md)
for a complete overview of how these components integrate.

**Note:** Even though the underlying projects are modular and can be used
independently, this package pins specific version combinations that have been
validated together for reproducible evaluation results.

## Script Behavior

- **Idempotent:** Safe to run multiple times; skips already-installed components
- **Self-checking:** Validates environment (OS, GPU), package versions, and
  imports
- **Hard-fail:** Exits immediately on critical errors (missing Rust, failed
  package installs)
- **Sandbox-aware:** Prefers Firejail for isolation; running unsandboxed requires
  explicit opt-in
- **Persistent:** Runs evaluation in tmux session (survives disconnections)

## Output Summary

At completion, the script prints:

- Location of logs: `setup.log`, `humaneval_results/**`
- Evaluation duration (wall-clock time)
- Estimated cost (approximate: wall-time × $3.29/hr for H100 SXM5)

## Configuration

Customize via environment variables (set before running):

```bash
BASE_MODEL="meta-llama/Meta-Llama-3.1-8B-Instruct"  # Base model
CHECKPOINT_PATH="Superuser666-Sigil/..."             # Fine-tuned checkpoint
NUM_SAMPLES=100                                       # Samples per task
K_VALUES="1,10,100"                                   # Pass@k metrics
OUTPUT_DIR="./humaneval_results"                     # Output directory
SANDBOX_MODE="firejail"                              # Firejail by default; set to none to disable sandboxing
SEED=1234                                            # Random seed for reproducibility (default: 1234)
SKIP_ENV_CHECK=1                                      # Bypass OS/GPU checks
NONINTERACTIVE=1                                      # Auto-start evaluation
```

## Repository Structure

- **`eval_setup.sh`** - Main entry point and orchestration script
- **`eval_setup_config.sh`** - Centralized configuration and constants
- **`lib/`** - Modular function libraries (11 focused modules)
- **`scripts/`** - Python evaluation and validation scripts
  - `evaluate_humaneval.py` - HumanEval-Rust evaluation driver
  - `validate_ecosystem.py` - Ecosystem package validation
- **`docs/`** - Documentation
  - `RULE_ZERO_APPROACH.md` - Rule Zero philosophy and implementation
  - `adr/` - Architecture Decision Records
  - `runbooks/` - Operational runbooks
- **`tests/`** - Test suite (bats for bash, pytest for Python)
- **`eval_setup_readme.md`** - Detailed technical documentation

## Related Documentation

- **[Ecosystem Architecture][architecture]** - Complete overview of the
  SigilDERG ecosystem
- **[Rule Zero Approach](docs/RULE_ZERO_APPROACH.md)** - Core philosophy
- **[Evaluation Setup Guide](eval_setup_readme.md)** - Detailed technical
  documentation
- **[Security Policy](SECURITY.md)** - Security practices and reporting

[architecture]: https://github.com/Superuser666-Sigil/SigilDERG-Data_Production/blob/main/ARCHITECTURE.md

## License

Copyright (c) 2025 Dave Tofflemire, SigilDERG Project
