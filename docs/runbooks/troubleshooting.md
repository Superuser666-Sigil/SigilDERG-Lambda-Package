# Runbook: Troubleshooting

## Common Issues

### Environment Check Failures

**Symptom:** Script exits with "Unsupported OS" or "CUDA GPU not detected"

**Solution:**

```bash
# Bypass environment checks (use with caution)
SKIP_ENV_CHECK=1 ./eval_setup.sh
```

**Note:** Results may not be comparable to Lambda baseline when bypassing.

### Firejail Installation Failed

**Symptom:** "Firejail installation failed" error

**Solutions:**

Retry installation:

```bash
sudo apt-get update
sudo apt-get install -y firejail
```

Or run without sandbox (DANGEROUS for untrusted code):

```bash
SANDBOX_MODE=none ./eval_setup.sh
```

### Rust Not Found in Firejail Sandbox

**Symptom:** "Rust not found (Firejail mode checks host Rust)" or "Rust not accessible in Firejail sandbox"

**Cause:** Firejail restricts access to the home directory by default, so it cannot access `~/.cargo/bin/rustc` where Rust is typically installed.

**Automatic Fix (Recommended):** The setup script now automatically configures Firejail to allow access to `~/.cargo` using `--whitelist` and preserves the PATH environment variable. This should work automatically.

**Manual Verification:** If the automatic fix doesn't work, verify Rust is installed:

```bash
# Check if rustc is available
rustc --version

# If not, source cargo environment
source ~/.cargo/env
rustc --version
```

**Check Firejail Version:** Older Firejail versions may not support `--whitelist`. Update Firejail:

```bash
sudo apt-get update
sudo apt-get install --upgrade firejail
```

**Alternative:** If Firejail configuration continues to fail, you can run without sandboxing (DANGEROUS for untrusted code):

```bash
SANDBOX_MODE=none ./eval_setup.sh
```

**Technical Details:**

- Rust installs to `~/.cargo/bin/` by default
- Firejail restricts home directory access for security
- The fix uses `firejail --whitelist="$HOME/.cargo" --env=PATH` to allow access
- This preserves security while enabling Rust toolchain access

### HuggingFace Authentication Failed

**Symptom:** "Repository not found" or "Access denied" for Llama models

**Solutions:**

Accept model license at <https://huggingface.co/meta-llama/Meta-Llama-3.1-8B-Instruct>

Re-authenticate:

```bash
huggingface-cli login
```

Verify access:

```bash
huggingface-cli whoami
```

### PyTorch CUDA Mismatch

**Symptom:** "CUDA error" or "No CUDA GPUs available"

**Solutions:**

Check CUDA version:

```bash
nvidia-smi | head -3
```

Verify PyTorch CUDA:

```bash
python -c "import torch; print(torch.cuda.is_available())"
```

Reinstall matching PyTorch:

```bash
pip install torch==2.4.0+cu124 -f https://download.pytorch.org/whl/torch_stable.html
```

### Out of Memory (OOM)

**Symptom:** "CUDA out of memory" during generation

**Solutions:**

Reduce batch size:

```bash
python evaluate_humaneval.py --batch-size 16
```

Reduce samples per task:

```bash
python evaluate_humaneval.py --num-samples 50
```

### Timeout During Evaluation

**Symptom:** Many samples fail with timeout

**Solutions:**

Increase timeout:

```bash
python evaluate_humaneval.py --timeout 30
```

Reduce workers (less contention):

```bash
python evaluate_humaneval.py --n-workers 12
```

### Package Version Conflicts

**Symptom:** ImportError or version mismatch warnings

**Solutions:**

Force reinstall ecosystem packages:

```bash
pip install --force-reinstall --no-cache-dir \
    "human-eval-rust>=2.3.0" \
    "sigil-pipeline>=2.3.0" \
    "sigilderg-finetuner>=3.0.0"
```

Check installed versions:

```bash
pip show human-eval-rust sigil-pipeline sigilderg-finetuner
```

### tmux Session Lost

**Symptom:** Cannot find running evaluation session

**Solutions:**

List sessions:

```bash
tmux list-sessions
```

Check if evaluation script is running:

```bash
ps aux | grep evaluate_humaneval
```

Restart evaluation:

```bash
source ~/.venvs/sigilderg-humaneval/bin/activate
python ~/.venvs/sigilderg-humaneval/evaluate_humaneval.py --output-dir ./humaneval_results
```

## Diagnostic Commands

### Check Environment

```bash
# System info
uname -a
cat /etc/os-release

# GPU info
nvidia-smi

# Python info
python --version
which python

# Package versions
pip freeze | grep -E "torch|transformers|human-eval|sigil"
```

### Check Rust

```bash
# Rust version
rustc --version
cargo --version

# Clippy available
cargo clippy --version
```

### Check Sandbox

```bash
# Firejail version
firejail --version

# Test sandbox
firejail --quiet echo "Sandbox works"
```

### Check Logs

```bash
# Setup log
tail -100 setup.log

# Find errors
grep -i error setup.log
grep -i warning setup.log
```

## Getting Help

If issues persist:

- Check `setup.log` for detailed error messages
- Review `eval_metadata.json` for environment details
- Open an issue at <https://github.com/Superuser666-Sigil/SigilDERG-Lambda-Package>
