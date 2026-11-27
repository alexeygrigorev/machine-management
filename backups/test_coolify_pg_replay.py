"""Run the PITR validator against archive filenames and an isolated Docker stub."""

import gzip
import io
import os
from pathlib import Path
import subprocess
import tarfile

import pytest


SCRIPT = Path(__file__).with_name("coolify-pg-replay.sh")


@pytest.mark.parametrize(
    "segment_size, start, following, expected",
    [
        (16777216, "0000000100000001000000FF", "000000010000000200000000",
         "replay reached the last staged WAL segment"),
        (67108864, "00000001000000010000003F", "000000010000000200000000",
         "replay reached the last staged WAL segment"),
        (16777216, "0000000100000001000000FF", "000000010000000200000001",
         "WAL GAP"),
        (16777216, "0000000100000001000000FF", "000000020000000200000000",
         "WAL TIMELINE CHANGE"),
    ],
)
def test_wal_log_rollover(tmp_path, segment_size, start, following, expected):
    base = tmp_path / "base.tar"
    with tarfile.open(base, "w") as archive:
        label = f"START WAL LOCATION: 0/0 (file {start})\n".encode()
        entry = tarfile.TarInfo("backup_label")
        entry.size = len(label)
        archive.addfile(entry, io.BytesIO(label))
    wal = tmp_path / "input"
    wal.mkdir()
    with gzip.open(wal / f"{start}.gz", "wb") as stream:
        stream.write(b"fixture")
    (wal / following).write_bytes(b"fixture")

    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    docker = bin_dir / "docker"
    docker.write_text("""#!/usr/bin/env bash
case "$*" in
  *" --entrypoint pg_controldata "*) printf 'Bytes per WAL segment: %s\n' "$TEST_SEGMENT_SIZE" ;;
  *"pg_is_in_recovery"*) echo f ;;
  *"pg_last_wal_replay_lsn"*) echo t ;;
esac
""")
    docker.chmod(0o755)
    for tool in ("psql", "pg_restore"):
        (bin_dir / tool).symlink_to("/bin/true")
    env = {
        **os.environ,
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "WORKDIR": str(tmp_path / "work"),
        "TEST_SEGMENT_SIZE": str(segment_size),
    }
    result = subprocess.run(
        ["bash", str(SCRIPT), "--mode", "pitr", "--base", str(base), "--wal-dir", str(wal), "--keep"],
        env=env, text=True, capture_output=True, timeout=12,
    )
    assert expected in result.stdout, result.stdout + result.stderr
    assert result.returncode == (0 if expected.startswith("replay reached") else 1)
