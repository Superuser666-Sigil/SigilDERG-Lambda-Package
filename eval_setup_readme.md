
# HumanEval-Rust Evaluation Setup Script

This evaluation harness (`eval_setup.sh` and supporting modules) provides a complete setup and execution pipeline for running the **HumanEval-Rust** benchmark on the SigilDERG Rust QLoRA model and its base model. It's designed as a **reproducible, H100-targeted evaluation pipeline** that Lambda (or any reviewer) can run end-to-end and get directly comparable results.

## Script Structure

The evaluation harness is organized as a modular system for maintainability and clarity:

- **`eval_setup.sh`** - Main entry point and orchestration script (~200 lines)
- **`eval_setup_config.sh`** - Centralized configuration and constants
- **`lib/`** - Modular function libraries:
  - `logging.sh` - Logging utilities
  - `environment.sh` - Environment validation
  - `system_deps.sh` - System package installation
  - `python_env.sh` - Python environment setup (pyenv, venv)
  - `pytorch.sh` - PyTorch and Flash Attention installation
  - `sigilderg.sh` - SigilDERG ecosystem component installation
  - `rust.sh` - Rust toolchain installation
  - `sandbox.sh` - Docker/Firejail sandbox verification and fallback
  - `cli_tools.sh` - GitHub and HuggingFace CLI installation
  - `evaluation.sh` - Evaluation script generation
  - `tmux.sh` - tmux session management
- **`scripts/evaluate_humaneval.py`** - Standalone Python evaluation script (extracted from embedded heredoc)

This modular structure provides clear separation of concerns, making the codebase easier to maintain, test, and extend.

---

## What the script does

At a high level, the script:

1. **Verifies the target environment**

   - Ensures it’s running on **Ubuntu 22.04** with an **NVIDIA H100 GPU** via `nvidia-smi`.
   - Exits with a clear error if the environment doesn’t match.
   - You can override this with `SKIP_ENV_CHECK=1` if you deliberately want to run elsewhere.

2. **Installs system dependencies**

   - Uses `apt-get` to install build tools and libraries required for:
     - Python compilation (`build-essential`, SSL/zlib/etc.)
     - Rust and Cargo
     - `tmux` (for persistent eval sessions)
   - Checks for Docker availability (for sandboxing) and attempts to start it if installed but not running; does not install Docker automatically.
   - Leaves system upgrades to the user; it only installs what it needs.

3. **Bootstraps Python via pyenv and sets up a virtualenv**

   - Installs `pyenv` into your home directory (if not already present).
   - Builds and pins **Python 3.12.11**.
   - Creates a dedicated virtual environment at `~/.venvs/sigilderg-humaneval`.
   - Ensures `pip`, `setuptools`, and `wheel` are up to date inside that venv.

4. **Installs a CUDA-compatible PyTorch stack**

   - Detects the installed CUDA version with `nvidia-smi`.
   - Installs a **specific PyTorch + CUDA wheel** based on detected CUDA version:
     - **PyTorch 2.4.0** with CUDA 12.4 support (default for most H100 setups)
     - **PyTorch 2.7.1** with CUDA 12.8 support (for newer CUDA 12.8/12.9 installations)
   - Optionally installs **FlashAttention 2** for faster inference, with a safe fallback if installation fails.
   - Installs supporting libraries:
     - `transformers`, `accelerate`, `peft`, `bitsandbytes`, `huggingface-hub`, `termcolor>=3.2.0` (for ecosystem compatibility), `jsonlines`, etc.

5. **Installs the SigilDERG ecosystem and HumanEval-Rust**

   - Installs **`human-eval-rust`** from PyPI with a minimum version of **1.4.4** (required for enhanced prompt format, result schema, compile rate tracking, main-free rate tracking, rustc preflight checks, never-dropping completions, Docker/Finetuner parity, Rust 1.91.1 Docker image, and bug fixes), and verifies the version.
     - If PyPI fails or the version is wrong, it falls back to installing directly from the GitHub repo.
   - Installs **`sigil-pipeline`** (minimum version 1.2.1 for termcolor compatibility) and **`sigilderg-finetuner`** from PyPI first, with GitHub fallbacks if needed.
   - Verifies that key modules can be imported inside the venv.

6. **Installs Rust and checks toolchain**

   - Installs Rust via `rustup` if it’s not already present.
   - Ensures `rustc` and `cargo` are available and functional.
   - This is required for `human-eval-rust` to compile and run the benchmark harness.

7. **Installs optional CLIs (GitHub and Hugging Face)**

   - Installs `gh` (GitHub CLI) and `huggingface_hub`’s `hf` CLI.
   - Adds them to your PATH via `~/.bashrc`.
   - In **interactive mode**, it offers to log you in; in **NONINTERACTIVE** mode, it skips auth and logs how to do it manually later.

8. **Copies the evaluation driver (`evaluate_humaneval.py`)**

   The script copies the Python evaluation script from `scripts/evaluate_humaneval.py` to the virtual environment. This Python script:

   - Loads both models (configurable via CLI arguments):
     - The **base model** (default: `meta-llama/Meta-Llama-3.1-8B-Instruct`), and  
     - The **Rust QLoRA fine-tuned checkpoint** (default: `Superuser666-Sigil/Llama-3.1-8B-Instruct-Rust-QLora/checkpoint-9000`)
   - Supports skipping base or finetuned model evaluation via `--skip-base` or `--skip-finetuned` flags.
   - Auto-selects device (`cuda` if available, otherwise `cpu`) unless overridden with `--device`.
   - Seeds all relevant RNGs (`python`, `numpy`, `torch`) for reproducibility (default seed: 1234).
   - Uses `human-eval-rust` to:
     - Generate completions for each HumanEval-Rust problem.
     - Execute them in a sandbox (Docker or firejail if available).
     - Compute pass@k metrics.
   - Runs **both modes automatically by default**:
     - **No-policy** (raw model behavior) - runs first
     - **Policy-enforced** (with SigilDERG policy hooks enabled) - runs second
   - Uses H100-optimized defaults:
     - 24 parallel workers (26 vCPUs - 2 reserved)
     - 10 second timeout per sample
     - Batch size of 32 for generation
     - 100 samples per task (configurable)
     - k-values: 1, 10, 100 (configurable)
   - Writes outputs to a structured directory:
     - `no-policy/` and `policy/` each contain:
       - Sample files: `base_model_samples.jsonl` and `finetuned_model_samples.jsonl`
       - Metrics JSON: `metrics.json` (contains base and finetuned results)
       - Human-readable report: `comparison_report.md`
     - A `combined_summary.md` at the root compares both modes and models.
     - An `eval_metadata.json` at the root captures environment and config:
       - OS, GPU name, CUDA availability
       - Python and package versions
       - `pip freeze` snapshot of the venv
       - All CLI arguments (seed, batch size, k-values, etc.)
       - Which modes ran and where their results live.

9. **Runs evaluation in a tmux session (or foreground)**

   - By default, the script offers to start a `tmux` session (`sigilderg-eval`) and run the Python evaluation inside it, so you can detach and let it run in the background.
   - In **NONINTERACTIVE** mode (`NONINTERACTIVE=1`), it:
     - Skips all prompts.
     - Kills any existing `sigilderg-eval` session and starts a fresh one.
     - Leaves it running without trying to attach.
   - If `tmux` is missing, it falls back to running the evaluation in the current shell.

---

## Why it’s built this way

This script is deliberately **opinionated** and **narrowly targeted**. The design choices are all about **reproducibility and auditability** for the Lambda AI grant:

1. **Strict environment assumptions**

   - Locking to **Ubuntu 22.04 + H100** reduces “it works here but not there” variability.
   - If someone wants to experiment on a different machine, they have to explicitly opt out with `SKIP_ENV_CHECK=1`, making it clear they’re leaving the validated regime.

2. **Version pinning instead of “latest”**

   - Python, PyTorch, CUDA wheels, and key libraries are all pinned to specific versions.
   - `human-eval-rust`, `sigil-pipeline`, and `sigilderg-finetuner` are validated at install time.
   - This ensures that the environment used for the reported results can be recreated later, even if upstream packages change.

3. **Robustness to package source issues**

   - PyPI can break, delist, or move packages.
   - The script falls back to GitHub source installs for critical components, so the eval remains runnable as long as the repos exist.

4. **Explicit sandboxing for generated code**

   - The benchmark runs arbitrary model-generated Rust code.
   - The script favors Docker (or firejail) when available to provide isolation.
   - If sandboxing isn’t available, it logs that clearly so reviewers know how code was executed.

5. **Modular architecture with clear separation of concerns**

   - The evaluation harness is organized into focused modules, each with a single responsibility:
     - Configuration, logging, and environment validation
     - System dependencies, Python environment, and ML libraries
     - Sandbox verification, CLI tools, and evaluation orchestration
   - The main bash script (`eval_setup.sh`) handles **environment setup** and orchestration.
   - The Python script (`scripts/evaluate_humaneval.py`) handles **model loading, sampling, scoring, and reporting**.
   - This modular structure makes it easier for reviewers to:
     - Inspect or modify specific components without affecting others
     - Understand the codebase through focused, single-purpose modules
     - Test individual components in isolation

6. **Detailed metadata for reviewers**

   - `eval_metadata.json` and related outputs give Lambda a precise picture of:
     - What ran (models, seeds, hyperparameters).
     - Where it ran (OS, GPU, CUDA, package versions).
   - This is critical for a research/grant context: it shows that the reported numbers are not “mystery results” but reproducible experiments with a documented chain of evidence.

---

## How to use it (quick start)

From a fresh Ubuntu 22.04 + H100 machine:

```bash
chmod +x eval_setup.sh

# Strict, non-interactive run (e.g., CI / repro):
NONINTERACTIVE=1 ./eval_setup.sh

# Or interactive run (prompts + optional auth):
./eval_setup.sh
```

### Configuration options

You can customize the evaluation via environment variables before running the script:

- `BASE_MODEL`: Base model path (default: `meta-llama/Meta-Llama-3.1-8B-Instruct`)
- `CHECKPOINT_PATH`: Fine-tuned checkpoint path (default: `Superuser666-Sigil/Llama-3.1-8B-Instruct-Rust-QLora/checkpoint-9000`)
- `NUM_SAMPLES`: Samples per task (default: `100`)
- `K_VALUES`: Comma-separated k-values for pass@k metrics (default: `1,10,100`)
- `OUTPUT_DIR`: Output directory (default: `./humaneval_results`)
- `SANDBOX_MODE`: Sandbox mode - `firejail`, `none`, or empty for auto-detect (default: auto-detect Firejail)
- `SKIP_ENV_CHECK`: Set to `1` to bypass Ubuntu 22.04 + H100 environment check
- `NONINTERACTIVE`: Set to `1` for non-interactive mode (no prompts, auto-start evaluation)

The generated evaluation script also supports additional CLI arguments (see script help with `--help`).

### Output structure

After setup completes, results will be in:

- `./humaneval_results/no-policy/` - No-policy mode results:
  - `base_model_samples.jsonl` - Generated samples from base model
  - `finetuned_model_samples.jsonl` - Generated samples from fine-tuned model
  - `metrics.json` - Machine-readable metrics for both models
  - `comparison_report.md` - Human-readable comparison report
- `./humaneval_results/policy/` - Policy-enforced mode results (same structure as above)
- `./humaneval_results/combined_summary.md` - Combined summary comparing both modes
- `./humaneval_results/eval_metadata.json` - Complete environment and configuration metadata
