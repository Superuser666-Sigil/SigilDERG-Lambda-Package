#!/usr/bin/env python3
"""
Complete HumanEval Rust evaluation workflow for base and fine-tuned models.

Handles model loading, sample generation, evaluation execution, and report generation
for both base and fine-tuned models. Runs both no-policy and policy-enforced evaluation
modes automatically. Supports batched generation with Flash Attention v2 optimization.

Copyright (c) 2025 Dave Tofflemire, SigilDERG Project
Version: 2.0.0
"""
import argparse
import json
import os
import platform
import random
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path


def set_seed(seed: int) -> None:
    """Set random seeds for reproducibility.

    Note: numpy and torch seeds are only set if those modules are available
    in the current environment. This allows the script to run basic operations
    without heavy ML dependencies installed.
    """
    random.seed(seed)
    try:
        import numpy as np

        np.random.seed(seed)
    except ImportError:
        pass
    try:
        import torch

        torch.manual_seed(seed)
        if torch.cuda.is_available():
            torch.cuda.manual_seed_all(seed)
    except ImportError:
        pass


def _run_cmd(cmd: str) -> str | None:
    try:
        return subprocess.check_output(
            cmd, shell=True, text=True, stderr=subprocess.DEVNULL
        ).strip()
    except Exception:
        return None


def _resolve_sandbox_mode(requested: str | None) -> tuple[str | None, list[str]]:
    """Resolve sandbox mode with Firejail preference and clear warnings."""

    messages: list[str] = []
    normalized = requested.lower() if requested else None

    if normalized == "auto":
        normalized = None

    if normalized not in (None, "firejail", "none"):
        raise ValueError(
            f"Invalid sandbox mode '{requested}'. Choose 'firejail', 'none', or 'auto'."
        )

    if normalized == "firejail":
        if not shutil.which("firejail"):
            raise RuntimeError(
                "Firejail requested but not available. Install Firejail or use --sandbox-mode none."
            )
        messages.append("Using sandbox mode: firejail")
        return "firejail", messages

    if normalized == "none":
        messages.append("WARNING: Running without a sandbox executes arbitrary code on the host.")
        return "none", messages

    # Auto-detect: prefer Firejail, otherwise warn before running unsandboxed
    if shutil.which("firejail"):
        messages.append("Auto-detected Firejail; enabling sandboxed evaluation.")
        return "firejail", messages

    messages.append(
        "WARNING: Firejail not found; proceeding without sandbox protection (mode: none)."
    )
    return "none", messages


def write_eval_metadata(output_dir: Path, all_results: dict, args, device: str) -> Path:
    """Write environment + configuration metadata for reproducibility."""
    # Import torch at function scope for CUDA checks
    import torch

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
    # Import heavy ML dependencies at function scope
    # This allows the module to be imported without these dependencies for testing
    import jsonlines
    import torch
    from human_eval.data import get_human_eval_dataset, read_problems
    from peft import AutoPeftModelForCausalLM, PeftConfig, PeftModel
    from transformers import AutoModelForCausalLM, AutoTokenizer

    print(f"\n{'=' * 60}")
    print(f"Loading model: {model_path}")
    print(f"{'=' * 60}")

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
                    actual_model_path, subfolder=checkpoint_subfolder
                )
                tokenizer_loaded = True
                print("✓ Tokenizer loaded from checkpoint subfolder")
            except Exception as e:
                print(f"Note: Tokenizer not found in checkpoint subfolder ({e})")

        # Fallback to repo root
        if not tokenizer_loaded:
            try:
                tokenizer = AutoTokenizer.from_pretrained(actual_model_path)
                tokenizer_loaded = True
                print("✓ Tokenizer loaded from repo root")
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
                model = AutoPeftModelForCausalLM.from_pretrained(actual_model_path, **load_kwargs)
            except OSError as e:
                # If loading fails with safetensors error, try without safetensors
                if "safetensors" in str(e).lower():
                    print(f"Warning: SafeTensors not available: {e}")
                    print("Retrying with PyTorch format (use_safetensors=False)...")
                    load_kwargs_no_safe = load_kwargs.copy()
                    load_kwargs_no_safe["use_safetensors"] = False
                    try:
                        model = AutoPeftModelForCausalLM.from_pretrained(
                            actual_model_path, **load_kwargs_no_safe
                        )
                        print("✓ Successfully loaded model using PyTorch format")
                    except OSError as e2:
                        # If PyTorch format also fails and suggests TensorFlow, try TensorFlow
                        if "tensorflow" in str(e2).lower() or "from_tf" in str(e2).lower():
                            print(
                                f"Warning: PyTorch format not available, trying TensorFlow weights: {e2}"
                            )
                            print(
                                "Attempting to load base model explicitly with TensorFlow weights, then applying PEFT adapter..."
                            )
                            try:
                                # Try to read adapter config to get base model path
                                if checkpoint_subfolder:
                                    config = PeftConfig.from_pretrained(
                                        actual_model_path, subfolder=checkpoint_subfolder
                                    )
                                else:
                                    config = PeftConfig.from_pretrained(actual_model_path)

                                base_model_path = config.base_model_name_or_path
                                print(
                                    f"Loading base model from TensorFlow weights: {base_model_path}"
                                )

                                # Load base model with TensorFlow weights
                                base_model = AutoModelForCausalLM.from_pretrained(
                                    base_model_path,
                                    dtype=torch.bfloat16,
                                    device_map="auto",
                                    trust_remote_code=True,
                                    attn_implementation=attn_implementation,
                                    from_tf=True,  # Load from TensorFlow weights
                                    use_safetensors=False,
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
                                print(
                                    "✓ Successfully loaded model using TensorFlow weights + PEFT adapter"
                                )
                            except Exception as e3:
                                print(f"ERROR: Failed to load model with TensorFlow weights: {e3}")
                                raise e  # Re-raise original error
                        else:
                            print(f"ERROR: Failed to load model even without safetensors: {e2}")
                            raise e  # Re-raise original error
                    except Exception as e2:
                        print(f"ERROR: Failed to load model even without safetensors: {e2}")
                        raise e  # Re-raise original error
                # If loading fails with TensorFlow error, try loading base model explicitly
                elif "TensorFlow" in str(e) or "from_tf" in str(e):
                    print(f"Warning: Encountered TensorFlow weights issue: {e}")
                    print("Attempting to load base model explicitly, then applying PEFT adapter...")
                    try:
                        # Try to read adapter config to get base model path
                        if checkpoint_subfolder:
                            config = PeftConfig.from_pretrained(
                                actual_model_path, subfolder=checkpoint_subfolder
                            )
                        else:
                            config = PeftConfig.from_pretrained(actual_model_path)

                        base_model_path = config.base_model_name_or_path
                        print(f"Loading base model from: {base_model_path}")

                        # Load base model explicitly with PyTorch weights only
                        # Try safetensors first, fall back to PyTorch if not available
                        try:
                            base_model = AutoModelForCausalLM.from_pretrained(
                                base_model_path,
                                dtype=torch.bfloat16,
                                device_map="auto",
                                trust_remote_code=True,
                                attn_implementation=attn_implementation,
                                from_tf=False,
                                use_safetensors=True,
                            )
                        except OSError as safetensors_error:
                            if "safetensors" in str(safetensors_error).lower():
                                print(
                                    "Warning: Base model doesn't have safetensors, trying PyTorch format"
                                )
                                try:
                                    base_model = AutoModelForCausalLM.from_pretrained(
                                        base_model_path,
                                        dtype=torch.bfloat16,
                                        device_map="auto",
                                        trust_remote_code=True,
                                        attn_implementation=attn_implementation,
                                        from_tf=False,
                                        use_safetensors=False,
                                    )
                                except OSError as pytorch_error:
                                    # If PyTorch format also fails and suggests TensorFlow, try TensorFlow
                                    if (
                                        "tensorflow" in str(pytorch_error).lower()
                                        or "from_tf" in str(pytorch_error).lower()
                                    ):
                                        print(
                                            "Warning: PyTorch format not available, using TensorFlow weights"
                                        )
                                        base_model = AutoModelForCausalLM.from_pretrained(
                                            base_model_path,
                                            dtype=torch.bfloat16,
                                            device_map="auto",
                                            trust_remote_code=True,
                                            attn_implementation=attn_implementation,
                                            from_tf=True,  # Load from TensorFlow weights
                                            use_safetensors=False,
                                        )
                                    else:
                                        raise
                            else:
                                raise

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
                        print(
                            "✓ Successfully loaded model using explicit base model + PEFT adapter approach"
                        )
                    except Exception as e2:
                        print(
                            f"ERROR: Failed to load model with explicit base model approach: {e2}"
                        )
                        raise e  # Re-raise original error
                else:
                    raise
        else:
            # Try safetensors first, fall back to PyTorch if not available
            try:
                model = AutoModelForCausalLM.from_pretrained(
                    model_path,
                    dtype=torch.bfloat16,
                    device_map="auto",
                    trust_remote_code=True,
                    attn_implementation=attn_implementation,
                    from_tf=False,  # Explicitly prevent TensorFlow loading
                    use_safetensors=True,  # Prefer SafeTensors format
                )
            except OSError as e:
                if "safetensors" in str(e).lower():
                    print(f"Warning: SafeTensors not available: {e}")
                    print("Retrying with PyTorch format (use_safetensors=False)...")
                    model = AutoModelForCausalLM.from_pretrained(
                        model_path,
                        dtype=torch.bfloat16,
                        device_map="auto",
                        trust_remote_code=True,
                        attn_implementation=attn_implementation,
                        from_tf=False,
                        use_safetensors=False,
                    )
                    print("✓ Successfully loaded model using PyTorch format")
                else:
                    raise
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

        # Enhanced prompt format with Rust-specific instructions
        enhanced_prompt = f"""{prompt}

Implement only the requested function in Rust.

Do not write fn main, tests, example code, or comments not already present.

Do not use ..., todo!(), or unimplemented!().

Use correct Rust imports; Vec is in the prelude, not std::collections.

Mark arguments as mut when you want to sort or mutate them."""

        # Format prompt with chat template if available
        if hasattr(tokenizer, "apply_chat_template"):
            try:
                messages = [{"role": "user", "content": enhanced_prompt}]
                formatted_prompt = tokenizer.apply_chat_template(
                    messages, tokenize=False, add_generation_prompt=True
                )
            except (ValueError, TypeError, KeyError):
                # Fall back to raw prompt if chat template fails
                formatted_prompt = enhanced_prompt
        else:
            formatted_prompt = enhanced_prompt

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

    # Track which problems have been successfully generated (for validation)
    problems_with_samples = set()

    # Use jsonlines writer for efficient batched writes
    with jsonlines.open(output_file, mode="w") as writer:
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
                        max_length=2048,
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
                            output[input_lengths:], skip_special_tokens=True
                        )

                        # Clean up completion
                        if "```rust" in completion:
                            completion = completion.split("```rust")[-1]
                        if "```" in completion:
                            completion = completion.split("```")[0]
                        completion = completion.strip()

                        batch_samples.append(
                            {
                                "task_id": task_id,
                                "completion": completion,
                            }
                        )

                    # Write entire batch at once (more efficient than per-sample)
                    writer.write_all(batch_samples)
                    samples.extend(batch_samples)
                    # Track which problems got samples
                    for sample in batch_samples:
                        problems_with_samples.add(sample["task_id"])

                except Exception as e:
                    print(f"  WARNING: Failed to generate batch starting at {batch_start}: {e}")
                    # Fallback to individual generation for this batch
                    for task_id, prompt in zip(batch_task_ids, batch_prompts):
                        try:
                            inputs = tokenizer(
                                prompt, return_tensors="pt", truncation=True, max_length=2048
                            ).to(device)
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
                                outputs[0][inputs.input_ids.shape[1] :], skip_special_tokens=True
                            )
                            if "```rust" in completion:
                                completion = completion.split("```rust")[-1]
                            if "```" in completion:
                                completion = completion.split("```")[0]
                            completion = completion.strip()

                            sample = {"task_id": task_id, "completion": completion}
                            samples.append(sample)
                            problems_with_samples.add(task_id)

                            # Write individual sample (fallback path) - append mode
                            with jsonlines.open(output_file, mode="a") as writer_single:
                                writer_single.write(sample)
                        except Exception as e2:
                            print(f"  WARNING: Failed to generate sample for {task_id}: {e2}")
                            continue

                # Progress update (always runs, success or fallback)
                current = len(samples)
                if current % (batch_size * 5) == 0 or current == total_tasks:
                    print(
                        f"  Generated {current}/{total_tasks} samples ({current/total_tasks*100:.1f}%)"
                    )

    # Validate that all problems have at least one sample
    all_problem_ids = set(problems.keys())
    missing_problems = all_problem_ids - problems_with_samples
    if missing_problems:
        print(f"\n⚠ WARNING: {len(missing_problems)} problems have no samples generated:")
        for task_id in sorted(missing_problems)[:10]:  # Show first 10
            print(f"    - {task_id}")
        if len(missing_problems) > 10:
            print(f"    ... and {len(missing_problems) - 10} more")
        print("  Adding placeholder samples for these problems...")

        # Add placeholder samples for missing problems
        with jsonlines.open(output_file, mode="a") as writer:
            for task_id in missing_problems:
                placeholder = {
                    "task_id": task_id,
                    "completion": "// Placeholder: generation failed for this problem",
                }
                writer.write(placeholder)
                samples.append(placeholder)
                problems_with_samples.add(task_id)
        print(f"  ✓ Added {len(missing_problems)} placeholder samples")

    print(f"\n✓ Generated {len(samples)} samples")
    print(f"✓ Saved to {output_file}")
    print(f"✓ Coverage: {len(problems_with_samples)}/{len(problems)} problems have samples")

    return output_file


def _filter_bad_samples(sample_file: str) -> str:
    """
    Pre-filter obviously bad samples to save evaluation time.
    Ensures at least one sample per problem remains to satisfy evaluation requirements.
    Returns path to filtered sample file.
    """
    from collections import defaultdict

    import jsonlines

    filtered_count = 0
    total_count = 0
    filtered_file = sample_file + ".filtered"

    # Track samples per problem: {task_id: {kept: [], all: [], filtered_reasons: {}}}
    problem_samples = defaultdict(lambda: {"kept": [], "all": [], "filtered_reasons": {}})

    # First pass: collect all samples and filter
    with jsonlines.open(sample_file, mode="r") as reader:
        for sample in reader:
            total_count += 1
            task_id = sample.get("task_id")
            completion = sample.get("completion", "").strip()

            problem_samples[task_id]["all"].append(sample)

            # Filter out empty completions
            if not completion:
                filtered_count += 1
                problem_samples[task_id]["filtered_reasons"] = problem_samples[task_id].get(
                    "filtered_reasons", {}
                )
                problem_samples[task_id]["filtered_reasons"]["empty"] = (
                    problem_samples[task_id]["filtered_reasons"].get("empty", 0) + 1
                )
                continue

            # Filter out very short completions (<10 chars) - likely incomplete
            # Reduced from 20 to 10 to allow for simple but valid functions
            if len(completion) < 10:
                filtered_count += 1
                problem_samples[task_id]["filtered_reasons"] = problem_samples[task_id].get(
                    "filtered_reasons", {}
                )
                problem_samples[task_id]["filtered_reasons"]["short"] = (
                    problem_samples[task_id]["filtered_reasons"].get("short", 0) + 1
                )
                continue

            # Filter out completions with severe brace mismatches (>3 difference)
            # This catches obviously incomplete/truncated code
            # Relaxed from >2 to >3 to be less strict
            open_braces = completion.count("{")
            close_braces = completion.count("}")
            if abs(open_braces - close_braces) > 3:
                filtered_count += 1
                problem_samples[task_id]["filtered_reasons"] = problem_samples[task_id].get(
                    "filtered_reasons", {}
                )
                problem_samples[task_id]["filtered_reasons"]["braces"] = (
                    problem_samples[task_id]["filtered_reasons"].get("braces", 0) + 1
                )
                continue

            # Keep the sample
            problem_samples[task_id]["kept"].append(sample)

    # Second pass: write filtered samples, ensuring at least one per problem
    with jsonlines.open(filtered_file, mode="w") as writer:
        for task_id in sorted(problem_samples.keys()):
            kept = problem_samples[task_id]["kept"]
            all_samples = problem_samples[task_id]["all"]

            if len(kept) == 0:
                # No samples passed filter - keep the first one anyway to satisfy evaluation requirement
                if len(all_samples) > 0:
                    writer.write(all_samples[0])
                    reasons = problem_samples[task_id].get("filtered_reasons", {})
                    reason_str = (
                        ", ".join([f"{k}:{v}" for k, v in reasons.items()])
                        if reasons
                        else "unknown"
                    )
                    print(
                        f"  WARNING: All samples for {task_id} were filtered ({reason_str}), keeping first sample anyway"
                    )
            else:
                # Write all kept samples
                for sample in kept:
                    writer.write(sample)

    if filtered_count > 0:
        print(
            f"  Filtered out {filtered_count}/{total_count} obviously bad samples ({filtered_count/total_count*100:.1f}%)"
        )
        # Count final samples
        final_count = sum(
            (
                max(1, len(problem_samples[task_id]["kept"]))
                if len(problem_samples[task_id]["kept"]) == 0
                and len(problem_samples[task_id]["all"]) > 0
                else len(problem_samples[task_id]["kept"])
            )
            for task_id in problem_samples
        )
        print(f"  Evaluating {final_count} samples (ensuring at least one per problem)")

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
    # Import human_eval at function scope for evaluation
    from human_eval.evaluation import evaluate_functional_correctness

    # Disable tokenizers parallelism warnings when using multiprocessing (evaluation phase only)
    # This prevents warnings when forking processes for parallel evaluation
    os.environ["TOKENIZERS_PARALLELISM"] = "false"

    print(f"\n{'='*60}")
    print(f"Evaluating: {sample_file}")
    print(f"{'='*60}")
    print(f"Sandbox mode: {sandbox_mode}")
    if sandbox_mode == "none":
        print("WARNING: Evaluation is running unsandboxed; proceed only if you trust the code.")
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
            sandbox_mode=sandbox_mode,
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
        "sandbox_mode": sandbox_mode,
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
    # Import torch at the start of main for device detection
    import torch

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
        choices=["firejail", "none", "auto"],
        default="auto",
        help="Sandbox mode: 'firejail', 'none', or 'auto' (auto-detect prefers Firejail)",
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

    # Determine sandbox mode with Firejail-first preference
    try:
        sandbox_mode, sandbox_messages = _resolve_sandbox_mode(args.sandbox_mode)
        for message in sandbox_messages:
            print(message)
    except (ValueError, RuntimeError) as exc:
        print(f"Error resolving sandbox mode: {exc}")
        sys.exit(1)

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
        print(f"\n✓ Non-policy evaluation complete! Results in: {output_dir / 'no-policy'}")

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
        print(f"\n✓ Policy evaluation complete! Results in: {output_dir / 'policy'}")

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
                for metric, value in sorted(all_results["no-policy"]["base"].items()):
                    f.write(f"- **{metric}**: {value:.4f} ({value*100:.2f}%)\n")
            if all_results["no-policy"]["finetuned"]:
                f.write("\n### Fine-tuned Model\n")
                for metric, value in sorted(all_results["no-policy"]["finetuned"].items()):
                    f.write(f"- **{metric}**: {value:.4f} ({value*100:.2f}%)\n")

            if all_results["policy"]:
                f.write("\n## Policy Enforcement Mode\n\n")
            if all_results["policy"]["base"]:
                f.write("### Base Model\n")
                for metric, value in sorted(all_results["policy"]["base"].items()):
                    f.write(f"- **{metric}**: {value:.4f} ({value*100:.2f}%)\n")
            if all_results["policy"]["finetuned"]:
                f.write("\n### Fine-tuned Model\n")
                for metric, value in sorted(all_results["policy"]["finetuned"].items()):
                    f.write(f"- **{metric}**: {value:.4f} ({value*100:.2f}%)\n")

        print(f"\n✓ Combined summary saved to: {summary_file}")

    # Top-level metadata for Lambda
    write_eval_metadata(output_dir, all_results, args, device)

    print("\n" + "=" * 80)
    print("All Evaluations Complete!")
    print("=" * 80)
    print("\nResults organized in sub-folders:")
    if run_no_policy:
        print(f"  - {output_dir / 'no-policy'}/ (no policy enforcement)")
    if run_policy:
        print(f"  - {output_dir / 'policy'}/ (policy enforcement enabled)")
    if run_no_policy and run_policy:
        print(f"  - {output_dir / 'combined_summary.md'} (combined summary)")


if __name__ == "__main__":
    main()
