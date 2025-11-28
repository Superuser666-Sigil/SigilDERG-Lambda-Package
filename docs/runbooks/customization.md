# Runbook: Customization

## Environment Variables

Set these before running `eval_setup.sh`:

```bash
# Models
export BASE_MODEL="meta-llama/Meta-Llama-3.1-8B-Instruct"
export CHECKPOINT_PATH="Superuser666-Sigil/Llama-3.1-8B-Instruct-Rust-QLora/checkpoint-9000"

# Evaluation parameters
export NUM_SAMPLES=100        # Samples per task (1-200)
export K_VALUES="1,10,100"    # Pass@k values to compute
export SEED=1234              # Random seed for reproducibility (default: 1234)

# Output
export OUTPUT_DIR="./humaneval_results"

# Sandbox
export SANDBOX_MODE="firejail"  # or "none" (unsafe)

# Environment checks
export SKIP_ENV_CHECK=0    # Set to 1 to bypass OS/GPU checks
export NONINTERACTIVE=0    # Set to 1 for CI/automated runs
```

## Using Different Models

### Base Model

Replace the base model with any HuggingFace causal LM:

```bash
export BASE_MODEL="codellama/CodeLlama-7b-Instruct-hf"
./eval_setup.sh
```

### Fine-tuned Checkpoint

Use a different fine-tuned checkpoint:

```bash
export CHECKPOINT_PATH="your-username/your-model/checkpoint-XXXX"
./eval_setup.sh
```

### Skip Base Model

Evaluate only the fine-tuned model:

```bash
python evaluate_humaneval.py --skip-base
```

### Skip Fine-tuned Model

Evaluate only the base model:

```bash
python evaluate_humaneval.py --skip-finetuned
```

## Evaluation Parameters

### Sample Count

More samples improve pass@k estimates but take longer:

```bash
# Quick test (5-10 minutes)
python evaluate_humaneval.py --num-samples 10

# Standard evaluation (1-2 hours)
python evaluate_humaneval.py --num-samples 100

# High-confidence (4-8 hours)
python evaluate_humaneval.py --num-samples 200
```

### k-Values

Customize which pass@k metrics to compute:

```bash
# Standard
python evaluate_humaneval.py --k-values "1,10,100"

# Quick
python evaluate_humaneval.py --k-values "1,10"

# Comprehensive
python evaluate_humaneval.py --k-values "1,5,10,25,50,100"
```

### Generation Parameters

Adjust generation behavior:

```bash
python evaluate_humaneval.py \
    --batch-size 32 \         # Parallel generations
    --max-new-tokens 512 \    # Max tokens per completion
    --seed 1234               # Reproducibility seed
```

### Evaluation Parameters

Adjust evaluation behavior:

```bash
python evaluate_humaneval.py \
    --n-workers 24 \          # Parallel evaluation workers
    --timeout 10.0            # Seconds per sample
```

## Policy Modes

### Both Modes (Default)

```bash
python evaluate_humaneval.py
```

Results in `no-policy/` and `policy/` subdirectories.

### No-Policy Only

```bash
python evaluate_humaneval.py --no-policy-only
```

### Policy Only

```bash
python evaluate_humaneval.py --policy-only
```

## Sandbox Configuration

### Firejail (Default, Recommended)

```bash
python evaluate_humaneval.py --sandbox-mode firejail
```

### No Sandbox (Dangerous)

Only use with trusted models:

```bash
# Requires explicit confirmation
python evaluate_humaneval.py --sandbox-mode none
```

## Output Customization

### Custom Output Directory

```bash
python evaluate_humaneval.py --output-dir ./my_results
```

### Output Structure

```
my_results/
├── no-policy/
│   ├── base_model_samples.jsonl      # Raw completions
│   ├── finetuned_model_samples.jsonl
│   ├── metrics.json                   # Machine-readable
│   └── comparison_report.md           # Human-readable
├── policy/
│   └── ...
├── combined_summary.md                # Both modes compared
└── eval_metadata.json                 # Environment snapshot
```

## Hardware Optimization

### H100 (Default)

```bash
python evaluate_humaneval.py \
    --batch-size 32 \
    --n-workers 24
```

### A100 (40GB)

```bash
python evaluate_humaneval.py \
    --batch-size 16 \
    --n-workers 16
```

### A10G / RTX 4090 (24GB)

```bash
python evaluate_humaneval.py \
    --batch-size 8 \
    --n-workers 8
```

## Reproducibility

### Exact Reproduction

Using environment variable (recommended for smoke tests):

```bash
export SEED=1234
python evaluate_humaneval.py
```

Or using CLI argument:

```bash
python evaluate_humaneval.py --seed 1234
```

### Different Seeds

For statistical significance testing:

```bash
# Using environment variable
for seed in 1234 5678 9012; do
    export SEED=$seed
    python evaluate_humaneval.py \
        --output-dir "./results_seed_${seed}"
done

# Or using CLI argument
for seed in 1234 5678 9012; do
    python evaluate_humaneval.py \
        --seed $seed \
        --output-dir "./results_seed_${seed}"
done
```

