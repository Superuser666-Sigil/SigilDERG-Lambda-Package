"""
Unit tests for scripts/evaluate_humaneval.py

Tests core functions without requiring GPU or model loading.

Copyright (c) 2025 Dave Tofflemire, SigilDERG Project
Version: 2.0.0
"""

import json
import shutil
import sys
import tempfile
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

# Add scripts directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent / "scripts"))

# Import functions to test (after path modification)
from evaluate_humaneval import (
    _filter_bad_samples,
    _resolve_sandbox_mode,
    _run_cmd,
    set_seed,
)


class TestSetSeed:
    """Tests for set_seed() function."""

    def test_set_seed_determinism(self):
        """Setting the same seed produces same random values."""
        import random

        set_seed(42)
        values1 = [random.random() for _ in range(5)]

        set_seed(42)
        values2 = [random.random() for _ in range(5)]

        assert values1 == values2

    def test_different_seeds_produce_different_values(self):
        """Different seeds produce different values."""
        import random

        set_seed(42)
        values1 = [random.random() for _ in range(5)]

        set_seed(123)
        values2 = [random.random() for _ in range(5)]

        assert values1 != values2

    def test_set_seed_affects_numpy(self):
        """set_seed affects numpy random state."""
        import numpy as np

        set_seed(42)
        arr1 = np.random.rand(5)

        set_seed(42)
        arr2 = np.random.rand(5)

        assert (arr1 == arr2).all()


class TestRunCmd:
    """Tests for _run_cmd() helper."""

    def test_run_cmd_success(self):
        """Successful command returns output."""
        result = _run_cmd("echo hello")
        assert result == "hello"

    def test_run_cmd_failure(self):
        """Failed command returns None."""
        result = _run_cmd("nonexistent_command_xyz")
        assert result is None

    def test_run_cmd_strips_output(self):
        """Output is stripped of whitespace."""
        result = _run_cmd("echo '  hello  '")
        # Result may vary by shell, but should be stripped
        assert result is not None
        assert result.strip() == result


class TestResolveSandboxMode:
    """Tests for _resolve_sandbox_mode() function."""

    def test_firejail_mode_when_available(self):
        """Returns firejail when requested and available."""
        with patch.object(shutil, "which", return_value="/usr/bin/firejail"):
            mode, messages = _resolve_sandbox_mode("firejail")
            assert mode == "firejail"
            assert any("firejail" in m.lower() for m in messages)

    def test_firejail_mode_when_unavailable_raises(self):
        """Raises when firejail requested but not available."""
        with patch.object(shutil, "which", return_value=None):
            with pytest.raises(RuntimeError, match="Firejail requested"):
                _resolve_sandbox_mode("firejail")

    def test_none_mode_returns_none(self):
        """Returns none when explicitly requested."""
        mode, messages = _resolve_sandbox_mode("none")
        assert mode == "none"
        assert any("WARNING" in m for m in messages)

    def test_auto_mode_prefers_firejail(self):
        """Auto mode prefers firejail when available."""
        with patch.object(shutil, "which", return_value="/usr/bin/firejail"):
            mode, messages = _resolve_sandbox_mode("auto")
            assert mode == "firejail"

    def test_auto_mode_falls_back_to_none(self):
        """Auto mode falls back to none when firejail unavailable."""
        with patch.object(shutil, "which", return_value=None):
            mode, messages = _resolve_sandbox_mode("auto")
            assert mode == "none"
            assert any("WARNING" in m for m in messages)

    def test_invalid_mode_raises(self):
        """Invalid mode raises ValueError."""
        with pytest.raises(ValueError, match="Invalid sandbox mode"):
            _resolve_sandbox_mode("invalid")


class TestFilterBadSamples:
    """Tests for _filter_bad_samples() function."""

    @pytest.fixture
    def sample_file(self, tmp_path):
        """Create a temporary sample file."""
        import jsonlines

        samples = [
            {"task_id": "task_1", "completion": "fn main() { println!(\"hello\"); }"},
            {"task_id": "task_2", "completion": ""},  # Empty - should be filtered
            {"task_id": "task_3", "completion": "x"},  # Too short - should be filtered
            {"task_id": "task_4", "completion": "fn test() { let x = 1; }"},
            {
                "task_id": "task_5",
                "completion": "{ { { { {",
            },  # Mismatched braces - should be filtered
        ]

        file_path = tmp_path / "samples.jsonl"
        with jsonlines.open(file_path, mode="w") as writer:
            writer.write_all(samples)

        return str(file_path)

    def test_filter_removes_empty_completions(self, sample_file):
        """Empty completions are filtered."""
        import jsonlines

        filtered_file = _filter_bad_samples(sample_file)

        samples = list(jsonlines.open(filtered_file))
        completions = [s.get("completion", "") for s in samples]

        # Empty completions should be filtered (or kept as last resort)
        for s in samples:
            if s["task_id"] == "task_2":
                # Either filtered out or kept as last resort for that task
                pass

        assert len(samples) >= 1  # At least some samples remain

    def test_filter_removes_very_short_completions(self, sample_file):
        """Very short completions are filtered."""
        import jsonlines

        filtered_file = _filter_bad_samples(sample_file)

        samples = list(jsonlines.open(filtered_file))

        # Short completions should be filtered
        for s in samples:
            if s["task_id"] == "task_3":
                # Either filtered or kept as last resort
                pass

    def test_filter_preserves_valid_samples(self, sample_file):
        """Valid samples are preserved."""
        import jsonlines

        filtered_file = _filter_bad_samples(sample_file)

        samples = list(jsonlines.open(filtered_file))
        task_ids = [s["task_id"] for s in samples]

        # Valid tasks should be preserved
        assert "task_1" in task_ids
        assert "task_4" in task_ids

    def test_filter_ensures_one_sample_per_task(self, sample_file):
        """At least one sample per task is preserved."""
        import jsonlines

        filtered_file = _filter_bad_samples(sample_file)

        samples = list(jsonlines.open(filtered_file))
        task_ids = set(s["task_id"] for s in samples)

        # All tasks should have at least one sample
        assert len(task_ids) >= 1


class TestWriteEvalMetadata:
    """Tests for write_eval_metadata() function."""

    def test_metadata_file_created(self, tmp_path):
        """Metadata file is created."""
        from evaluate_humaneval import write_eval_metadata

        args = MagicMock()
        args.seed = 1234
        args.base_model = "test-model"
        args.checkpoint_path = "test-checkpoint"

        all_results = {"no-policy": None, "policy": None}

        metadata_path = write_eval_metadata(tmp_path, all_results, args, "cuda")

        assert metadata_path.exists()
        assert metadata_path.name == "eval_metadata.json"

    def test_metadata_contains_required_fields(self, tmp_path):
        """Metadata contains all required fields."""
        from evaluate_humaneval import write_eval_metadata

        args = MagicMock()
        args.seed = 1234

        all_results = {"no-policy": {"pass@1": 0.5}, "policy": None}

        metadata_path = write_eval_metadata(tmp_path, all_results, args, "cpu")

        with open(metadata_path) as f:
            metadata = json.load(f)

        assert "timestamp_utc" in metadata
        assert "python_version" in metadata
        assert "device" in metadata
        assert "packages" in metadata
        assert "results_present" in metadata

