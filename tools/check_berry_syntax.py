#!/usr/bin/env python3
"""Parse Berry source with the Berry interpreter without running its top-level code."""

from __future__ import annotations

import argparse
import subprocess
import tempfile
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", type=Path, required=True)
    parser.add_argument("sources", type=Path, nargs="+")
    args = parser.parse_args()

    with tempfile.TemporaryDirectory() as temp_dir:
        for index, source_path in enumerate(args.sources):
            source = source_path.read_text(encoding="utf-8")
            wrapped_source = "if false\n" + source + "\nend\n"
            wrapped_path = Path(temp_dir) / f"syntax_check_{index}.be"
            wrapped_path.write_text(wrapped_source, encoding="utf-8")
            subprocess.run([str(args.compiler), str(wrapped_path)], check=True)

    print("Berry syntax OK: " + ", ".join(str(source) for source in args.sources))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
