#!/usr/bin/env bash
#$ -S /bin/bash
#$ -cwd
#$ -V
#$ -j y
# qsub -N, -o, -pe, -l h_rt, -l mem_free, and -v are set by the driver.
#
# Stage 00: filter -> subsample -> assemble (7 assemblers x 4 subsets) -> autocycler combine.
# Wraps autocycler_sge.sh, which itself qsubs the 28 inner assembler jobs and polls.
# Required env (set by driver via qsub -v):
#   CONFIG  - path to pipeline.config.sh
#   ISOLATE - isolate id

set -euo pipefail
source ~/miniforge3/etc/profile.d/conda.sh

: "${CONFIG:?CONFIG not set}"
: "${ISOLATE:?ISOLATE not set}"

source "$CONFIG"
source "${PIPELINE_ROOT}/bin/lib/common.sh"
parse_samples "${PIPELINE_ROOT}/config/samples.tsv"
resolve_isolate "$ISOLATE"

ensure_dir "$ISOLATE_RUN_DIR"

log_info "Stage 00 (assemble) starting for ${ISOLATE}"
log_info "  reads:    ${ISOLATE_ONT_FASTQ}"
log_info "  run_dir:  ${ISOLATE_RUN_DIR}"
log_info "  read_type:${ISOLATE_READ_TYPE}"

# autocycler_sge.sh expects to be invoked directly (not under qsub) — but here
# we ARE inside an SGE job, which is fine: it will qsub the 28 assembler jobs
# and poll qstat. The outer job holds 1 slot for the duration; small price for
# clean -hold_jid chaining of stages 01-04.
"${PIPELINE_ROOT}/bin/autocycler_sge.sh" \
    "${ISOLATE_ONT_FASTQ}" \
    --outdir "${ISOLATE_RUN_DIR}" \
    --threads "${ASSEMBLY_THREADS}" \
    --read-type "${ISOLATE_READ_TYPE}" \
    --max-time "${ASSEMBLY_MAX_TIME}" \
    --max-mem "${ASSEMBLY_MAX_MEM}" \
    --max-concurrent "${ASSEMBLY_MAX_CONCURRENT}"

mark_stage_done "$ISOLATE_RUN_DIR" "00"
log_info "Stage 00 (assemble) complete for ${ISOLATE}"
