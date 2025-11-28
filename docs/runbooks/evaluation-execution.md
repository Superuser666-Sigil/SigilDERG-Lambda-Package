# Runbook: Evaluation Execution

## Prerequisites

- Ubuntu 22.04 with NVIDIA H100 GPU
- Internet access for package downloads
- HuggingFace account with model access (for gated models)
- ~30 minutes for initial setup

## Quick Start

### Option 1: One-Line Setup

```bash
curl -sS https://raw.githubusercontent.com/Superuser666-Sigil/SigilDERG-Lambda-Package/main/eval_setup.sh | bash
```

### Option 2: Clone and Run

```bash
git clone https://github.com/Superuser666-Sigil/SigilDERG-Lambda-Package.git
cd SigilDERG-Lambda-Package
chmod +x eval_setup.sh
./eval_setup.sh
```

## Step-by-Step Execution

### 1. Initial Setup

The script will:

1. Validate environment (Ubuntu 22.04 + H100)
2. Install system dependencies
3. Install Python 3.12.11 via pyenv
4. Create virtual environment
5. Install PyTorch with CUDA support
6. Install SigilDERG ecosystem packages
7. Install Rust toolchain
8. Verify Firejail sandbox

### 2. Authentication

When prompted, authenticate with:

- **GitHub CLI** - For accessing private repos (optional)
- **HuggingFace CLI** - For accessing gated models (required for Llama)

### 3. Run Evaluation

The script offers to start evaluation immediately. Options:

```bash
# Interactive mode (default)
./eval_setup.sh

# Non-interactive mode (auto-start)
NONINTERACTIVE=1 ./eval_setup.sh
```

### 4. Monitor Progress

If running in tmux:

```bash
# Attach to running session
tmux attach -t sigilderg-eval

# Detach (Ctrl+B, then D)

# Check if session exists
tmux list-sessions
```

## Output Structure

After evaluation completes:

```
humaneval_results/
├── no-policy/
│   ├── base_model_samples.jsonl
│   ├── finetuned_model_samples.jsonl
│   ├── metrics.json
│   └── comparison_report.md
├── policy/
│   ├── base_model_samples.jsonl
│   ├── finetuned_model_samples.jsonl
│   ├── metrics.json
│   └── comparison_report.md
├── combined_summary.md
└── eval_metadata.json
```

## Key Metrics

Look for these in `metrics.json`:

- **pass@1** - Probability of passing with 1 sample
- **pass@10** - Probability of passing with 10 samples
- **pass@100** - Probability of passing with 100 samples
- **compile_rate** - Percentage of samples that compile
- **main_free_rate** - Percentage without fn main (policy compliance)

## Verification Checklist

After evaluation:

- [ ] `setup.log` shows no errors
- [ ] `eval_metadata.json` has complete environment info
- [ ] `combined_summary.md` shows results for both models
- [ ] `comparison_report.md` shows improvement metrics
- [ ] All 164 HumanEval problems were evaluated

## Next Steps

- Review [troubleshooting.md](troubleshooting.md) if issues occurred
- Review [customization.md](customization.md) to run with different models

