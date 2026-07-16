#!/usr/bin/env bash
#$ -S /bin/bash
#$ -cwd
#$ -V
#$ -j y
# qsub -N, -o, -pe, -l h_rt, -l mem_free, and -v are set by the driver.
#
# Stage 03: short-read polishing (Polypolish + pypolca).
# Required env: CONFIG, ISOLATE

set -euo pipefail
source ~/miniforge3/etc/profile.d/conda.sh

: "${CONFIG:?CONFIG not set}"
: "${ISOLATE:?ISOLATE not set}"

source "$CONFIG"
source "${PIPELINE_ROOT}/bin/lib/common.sh"
parse_samples "${PIPELINE_ROOT}/config/samples.tsv"
resolve_isolate "$ISOLATE"

require_stage_done "$ISOLATE_RUN_DIR" "02"
threads="${NSLOTS:-${POLISH_PE}}"

conda activate pypolca

INPUT_ASSEMBLY="${ISOLATE_RUN_DIR}/medaka/consensus.fasta"
R1="${ISOLATE_ILLUMINA_R1}"
R2="${ISOLATE_ILLUMINA_R2}"
OUT_DIR="${ISOLATE_RUN_DIR}/shortreads_polish"

ensure_dir "$OUT_DIR"
cd "$OUT_DIR"

log_info "Short-read polishing ${ISOLATE} (threads=${threads})"

cp "$INPUT_ASSEMBLY" medaka.fasta
bwa index medaka.fasta
bwa mem -t "${threads}" -a medaka.fasta "$R1" > "${ISOLATE}_alignments_1.sam"
bwa mem -t "${threads}" -a medaka.fasta "$R2" > "${ISOLATE}_alignments_2.sam"

polypolish filter \
    --in1 "${ISOLATE}_alignments_1.sam" \
    --in2 "${ISOLATE}_alignments_2.sam" \
    --out1 filtered_1.sam \
    --out2 filtered_2.sam
polypolish polish medaka.fasta filtered_1.sam filtered_2.sam > medaka_polypolish.fasta
rm -f *.amb *.ann *.bwt *.pac *.sa *.sam

# pypolca is on PATH inside the env
pypolca run --careful \
    -a medaka_polypolish.fasta \
    -1 "$R1" -2 "$R2" \
    -t "${threads}" \
    -o pypolca

cp pypolca/pypolca_corrected.fasta medaka_polypolish_pypolca.fasta
rm -rf pypolca

mark_stage_done "$ISOLATE_RUN_DIR" "03"
log_info "Short-read polish complete: ${OUT_DIR}/medaka_polypolish_pypolca.fasta"
