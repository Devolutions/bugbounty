#!/usr/bin/env python3
"""Clean Docker containers and data folders for DVLS Docker setup."""

import os
import shutil
import stat
import subprocess
import sys
from pathlib import Path

# Windows consoles default to cp1252 and cannot encode the glyphs below. Kept here rather than in
# the callers because clean.py is imported by the other scripts here - including ones with no
# glyphs of their own, which used to die on their first print.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass


def _force_remove(path: Path) -> None:
    """Remove a directory tree, clearing read-only flags on Windows if needed."""
    def _on_exc(func, fpath, exc):
        # Clear read-only bit and retry (Windows can leave files read-only)
        os.chmod(fpath, stat.S_IWRITE)
        func(fpath)

    shutil.rmtree(path, onexc=_on_exc)


def run(script_dir: Path) -> None:
    print("🧹 Cleaning Docker containers and data folders...")

    print("\n🐳 Stopping and removing Docker containers...")
    # -v also drops the pgdata named volume, which is where the database now lives.
    # --remove-orphans is load-bearing on the SQL Server upgrade path: compose only knows the
    # services in the CURRENT file, so the retired sqlserver_db container survives a plain `down`.
    # It holds 172.30.0.44 - the address the new postgres_db claims - so the new stack cannot
    # start, and it keeps its published host ports and old credentials reachable meanwhile.
    result = subprocess.run(["docker", "compose", "down", "-v", "--remove-orphans"], cwd=script_dir)
    if result.returncode == 0:
        print("   ✅ Docker containers stopped and removed")
    else:
        print(f"   ⚠️  Docker compose down completed with warnings (exit code: {result.returncode})")

    print("\n🧹 Cleaning data folders...")
    # data-sql is the retired SQL Server working directory. It is deliberately NOT recreated
    # below - the stack has no SQL Server - but it must still be REMOVED: .gitignore records
    # that it holds a plaintext SA password (current_sa_password.txt) beside the old .mdf/.ldf
    # files, and a command advertised as a clean install was leaving ~167 MB of it on disk.
    for folder in ("data-dvls", "data-sql"):
        p = script_dir / folder
        if p.exists():
            _force_remove(p)
            print(f"   ✅ Removed {folder}/")

    for folder in ("data-dvls",):
        p = script_dir / folder
        p.mkdir(parents=True, exist_ok=True)
        (p / ".gitkeep").touch()
    print("   ✅ Recreated data folders with .gitkeep files")

    print("\n✅ Data folders cleaned successfully")


if __name__ == "__main__":
    run(Path(__file__).parent.resolve())
