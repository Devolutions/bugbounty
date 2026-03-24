#!/usr/bin/env python3
"""Redirect stdout/stderr to both console and log the output of them."""

from __future__ import annotations

import sys
from pathlib import Path


class _Tee:
    def __init__(self, *streams):
        self._streams = streams

    def write(self, data):
        for s in self._streams:
            s.write(data)
            s.flush()

    def flush(self):
        for s in self._streams:
            s.flush()


def setup(script_dir: Path) -> None:
    log_path = script_dir / "output.log"
    log_file = log_path.open("w", encoding="utf-8")
    sys.stdout = _Tee(sys.__stdout__, log_file)
    sys.stderr = _Tee(sys.__stderr__, log_file)
