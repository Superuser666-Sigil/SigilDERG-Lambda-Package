#!/usr/bin/env python3
"""
Validate SigilDERG ecosystem component installation.

Checks that all required packages are installed with correct versions and can be imported.
Used to verify the environment before running evaluation.

Copyright (c) 2025 Dave Tofflemire, SigilDERG Project
Version: 2.0.0
"""

import sys
from importlib import import_module
from importlib.metadata import version as pkg_version

# Minimum version requirements
REQUIREMENTS: dict[str, str] = {
    "human-eval-rust": "2.1.0",
    "sigil-pipeline": "2.2.0",
    "sigilderg-finetuner": "2.9.0",
}

# Module names for import testing
MODULE_NAMES: dict[str, str] = {
    "human-eval-rust": "human_eval",
    "sigil-pipeline": "sigil_pipeline",
    "sigilderg-finetuner": "rust_qlora",
}


def parse_version(v: str) -> tuple[int, ...]:
    """Parse version string to tuple for comparison."""
    return tuple(int(x) for x in v.split(".")[:3])


def check_version(installed: str, required: str) -> bool:
    """Check if installed version meets requirement."""
    try:
        return parse_version(installed) >= parse_version(required)
    except (ValueError, TypeError):
        return False


def validate_package(pkg_name: str, min_version: str, module_name: str) -> dict:
    """Validate a single package."""
    result = {
        "package": pkg_name,
        "required_version": min_version,
        "installed_version": None,
        "import_success": False,
        "version_ok": False,
        "error": None,
    }

    # Check installed version
    try:
        result["installed_version"] = pkg_version(pkg_name)
    except Exception as e:
        result["error"] = f"Not installed: {e}"
        return result

    # Check version requirement
    result["version_ok"] = check_version(result["installed_version"], min_version)

    # Try importing
    try:
        import_module(module_name)
        result["import_success"] = True
    except Exception as e:
        result["error"] = f"Import failed: {e}"

    return result


def validate_all() -> list[dict]:
    """Validate all ecosystem packages."""
    results = []
    for pkg_name, min_version in REQUIREMENTS.items():
        module_name = MODULE_NAMES.get(pkg_name, pkg_name.replace("-", "_"))
        result = validate_package(pkg_name, min_version, module_name)
        results.append(result)
    return results


def print_results(results: list[dict]) -> bool:
    """Print validation results and return success status."""
    print("=" * 60)
    print("SigilDERG Ecosystem Validation")
    print("=" * 60)
    print()

    all_ok = True
    for r in results:
        status = "OK" if r["version_ok"] and r["import_success"] else "FAIL"
        if status == "FAIL":
            all_ok = False

        print(f"Package: {r['package']}")
        print(f"  Required: >= {r['required_version']}")
        print(f"  Installed: {r['installed_version'] or 'Not found'}")
        print(f"  Import: {'Success' if r['import_success'] else 'Failed'}")
        print(f"  Status: {status}")
        if r["error"]:
            print(f"  Error: {r['error']}")
        print()

    print("=" * 60)
    if all_ok:
        print("All ecosystem packages validated successfully!")
    else:
        print("Some packages failed validation. Please install/upgrade.")
    print("=" * 60)

    return all_ok


def main() -> int:
    """Main entry point."""
    results = validate_all()
    success = print_results(results)
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())

