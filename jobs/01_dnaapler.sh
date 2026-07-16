#!/usr/bin/env bash
#$ -S /bin/bash
#$ -cwd
#$ -V
#$ -j y
# qsub -N, -o, -pe, -l h_rt, -l mem_free, and -v are set by the driver.
#
# Stage 01: dnaapler reorientation of the autocycler consensus.
# Required env: CONFIG, ISOLATE

set -euo pipefail
source ~/miniforge3/etc/profile.d/conda.sh

: "${CONFIG:?CONFIG not set}"
: "${ISOLATE:?ISOLATE not set}"

source "$CONFIG"
source "${PIPELINE_ROOT}/bin/lib/common.sh"
RUN_DIR="$(isolate_run_dir "$ISOLATE")"
require_stage_done "$RUN_DIR" "00"
threads="${NSLOTS:-${DNAAPLER_PE}}"

conda activate autocycler

cd "$RUN_DIR"
mkdir -p logs
log_info "Starting Dnaapler reorientation for ${ISOLATE} (threads=${threads})"

# Reorient circular sequences with Dnaapler
dnaapler all \
    -i autocycler_out/consensus_assembly.gfa \
    -o dnaapler \
    -t "${threads}" \
    2> logs/dnaapler.stderr

# Convert the reoriented GFA back to FASTA
autocycler gfa2fasta \
    -i dnaapler/dnaapler_reoriented.gfa \
    -o dnaapler/dnaapler_reoriented.fasta \
    2>> logs/dnaapler.stderr

mark_stage_done "$RUN_DIR" "01"
log_info "Dnaapler reorientation complete: ${RUN_DIR}/dnaapler/dnaapler_reoriented.fasta"
