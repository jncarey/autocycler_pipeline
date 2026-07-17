#!/usr/bin/env bash
# One-time setup: provisions shared assets needed by the pipeline that aren't
# installed by the conda packages themselves.
#
# Currently: Plassembler's reference database, downloaded to
# $CONDA_PREFIX/plassembler_db — its own documented default fallback location,
# so every job that does `conda activate autocycler` finds it automatically
# with no further configuration. Safe to re-run; skips if already present.

set -euo pipefail

source ~/miniforge3/etc/profile.d/conda.sh
conda activate autocycler

db_marker="$CONDA_PREFIX/plassembler_db/plsdb_2023_11_03_v2.msh"
if [[ -f "$db_marker" ]]; then
    echo "Plassembler database already present at $CONDA_PREFIX/plassembler_db — skipping."
    exit 0
fi

echo "Downloading Plassembler database to $CONDA_PREFIX/plassembler_db..."
plassembler download -d "$CONDA_PREFIX/plassembler_db"
