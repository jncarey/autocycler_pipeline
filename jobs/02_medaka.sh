#!/usr/bin/env bash
#$ -S /bin/bash
#$ -cwd
#$ -V
#$ -j y
# qsub -N, -o, -pe, -l h_rt, -l mem_free, and -v are set by the driver.
#
# Stage 02: long-read polishing with Medaka.
# Required env: CONFIG, ISOLATE

set -euo pipefail
source ~/miniforge3/etc/profile.d/conda.sh

: "${CONFIG:?CONFIG not set}"
: "${ISOLATE:?ISOLATE not set}"

source "$CONFIG"
source "${PIPELINE_ROOT}/bin/lib/common.sh"
parse_samples "${PIPELINE_ROOT}/config/samples.tsv"
resolve_isolate "$ISOLATE"

require_stage_done "$ISOLATE_RUN_DIR" "01"
threads="${NSLOTS:-${MEDAKA_PE}}"

conda activate medaka
module load samtools/1.22 minimap2/2.26 htslib/1.22 bcftools/1.22

INPUT_ASSEMBLY="${ISOLATE_RUN_DIR}/dnaapler/dnaapler_reoriented.fasta"
LONG_READS="${ISOLATE_ONT_FASTQ}"

cd "${ISOLATE_RUN_DIR}"
log_info "Medaka polishing ${ISOLATE} with model ${ISOLATE_MEDAKA_MODEL} (threads=${threads})"

# Not using --bacteria flag because input fastq is r9 flow cell (per dev notes).
medaka_consensus \
    -i "$LONG_READS" \
    -d "$INPUT_ASSEMBLY" \
    -t "${threads}" \
    -o medaka \
    -m "${ISOLATE_MEDAKA_MODEL}"

mark_stage_done "$ISOLATE_RUN_DIR" "02"
log_info "Medaka complete: ${ISOLATE_RUN_DIR}/medaka/consensus.fasta"
