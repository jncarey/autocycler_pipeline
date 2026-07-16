#!/usr/bin/env bash
# Driver: queue the full assembly pipeline for one or more isolates.
#
# For each isolate:
#   stage 00 (assemble) -hold_jid-> 01 (dnaapler) -hold_jid-> 02 (medaka)
#       -hold_jid-> 03 (short-read polish) -hold_jid-> 04 (QC + variants)
#
# Per-isolate cap on inner assembler jobs: ASSEMBLY_MAX_CONCURRENT (passed to
#   autocycler_sge.sh -C from inside stage 00).
# Cluster-wide cap: GLOBAL_ASSEMBLY_MAX_CONCURRENT, enforced here by polling
#   `qstat` for jobs whose name starts with "ac_" before launching the next
#   isolate's stage 00.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/../config/pipeline.config.sh"
SAMPLES_DEFAULT="${SCRIPT_DIR}/../config/samples.tsv"

source "$CONFIG"
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --samples <tsv>       Samplesheet (default: ${SAMPLES_DEFAULT})
  --isolate <id[,id]>   Run only the listed isolate(s); comma-separated
  --from <00|01|02|03|04>  Resume: skip stages before this one
  --dry-run             Print qsub commands instead of executing
  -h, --help            Show this help

Environment:
  CONFIG can be overridden by setting it before invocation.
EOF
}

samples="$SAMPLES_DEFAULT"
isolate_filter=""
from_stage="00"
dry_run=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --samples)  samples="$2"; shift 2 ;;
        --isolate)  isolate_filter="$2"; shift 2 ;;
        --from)     from_stage="$2"; shift 2 ;;
        --dry-run)  dry_run=true; shift ;;
        -h|--help)  usage; exit 0 ;;
        *) log_error "unknown option: $1"; usage >&2; exit 1 ;;
    esac
done

case "$from_stage" in 00|01|02|03|04) ;; *) log_error "--from must be 00..04"; exit 1 ;; esac

parse_samples "$samples"

# Resolve which isolates to run
if [[ -n "$isolate_filter" ]]; then
    IFS=',' read -r -a target_isolates <<<"$isolate_filter"
else
    target_isolates=("${SAMPLE_ORDER[@]}")
fi

# Validate all targets are in the samplesheet
for iso in "${target_isolates[@]}"; do
    if [[ -z "${SAMPLE_BY_ISOLATE[$iso]+x}" ]]; then
        log_error "isolate '$iso' not in $samples"
        exit 1
    fi
done

ensure_dir "$RUNS_DIR"

# qsub_or_print: emits a qsub command, or runs it. Echoes the SGE job ID on
# success.
qsub_or_print() {
    if $dry_run; then
        echo "DRY: qsub" "$@" >&2
        echo "0"   # fake jobid
    else
        local out
        out="$(qsub "$@")"
        echo "$out" >&2
        # "Your job 12345 ("name") has been submitted"
        echo "$out" | grep -oP 'Your job \K[0-9]+'
    fi
}

# Wait until the global assembler-job count is below the cap.
wait_for_global_cap() {
    local cap="${GLOBAL_ASSEMBLY_MAX_CONCURRENT:-20}"
    while true; do
        local n
        n="$(count_global_assembler_jobs)"
        if (( n < cap )); then
            return 0
        fi
        log_info "Global assembler cap hit (${n}/${cap}); sleeping 60s..."
        sleep 60
    done
}

# Stage launcher. Echoes the new SGE job id.
#   $1 stage_no (00..04)
#   $2 stage_script
#   $3 isolate
#   $4 hold_jid (may be empty)
#   $5 pe slots
#   $6 h_rt
#   $7 mem_free
launch_stage() {
    local stage="$1" script="$2" isolate="$3" hold="$4" pe="$5" rt="$6" mem="$7"
    local run_dir="${RUNS_DIR}/${isolate}"
    local logs="${run_dir}/logs"
    ensure_dir "$logs"
    local name="iso_${isolate}_${stage}"
    local args=(
        -N "$name"
        -o "${logs}/${stage}.log"
        -j y
        -pe serial "$pe"
        -l "h_rt=${rt}"
        -l "mem_free=${mem}"
        -v "CONFIG=${CONFIG},ISOLATE=${isolate}"
    )
    [[ -n "$hold" ]] && args+=( -hold_jid "$hold" )
    args+=( "$script" )
    qsub_or_print "${args[@]}"
}

stage_ge() { [[ "$1" -ge "$2" ]]; }   # numeric >= for "00".."04"

for isolate in "${target_isolates[@]}"; do
    log_info "=== Queuing isolate: ${isolate} ==="
    prev_jid=""

    # Stage 00 (assemble) — gate on global cap before launching, since this is
    # the stage that fans out into ac_* assembler jobs.
    if [[ "$from_stage" == "00" ]]; then
        wait_for_global_cap
        prev_jid="$(launch_stage 00 "${JOBS_DIR}/00_assemble.sh" "$isolate" "" \
                       1 24:00:00 "${ASSEMBLY_MAX_MEM}")"
        log_info "  stage 00 -> jid=${prev_jid}"
    fi

    # 01 dnaapler
    if [[ "$from_stage" -le 1 ]]; then
        prev_jid="$(launch_stage 01 "${JOBS_DIR}/01_dnaapler.sh" "$isolate" "$prev_jid" \
                       "$DNAAPLER_PE" "$DNAAPLER_TIME" "$DNAAPLER_MEM")"
        log_info "  stage 01 -> jid=${prev_jid}"
    fi

    # 02 medaka
    if [[ "$from_stage" -le 2 ]]; then
        prev_jid="$(launch_stage 02 "${JOBS_DIR}/02_medaka.sh" "$isolate" "$prev_jid" \
                       "$MEDAKA_PE" "$MEDAKA_TIME" "$MEDAKA_MEM")"
        log_info "  stage 02 -> jid=${prev_jid}"
    fi

    # 03 short-read polish
    if [[ "$from_stage" -le 3 ]]; then
        prev_jid="$(launch_stage 03 "${JOBS_DIR}/03_shortreads_polish.sh" "$isolate" "$prev_jid" \
                       "$POLISH_PE" "$POLISH_TIME" "$POLISH_MEM")"
        log_info "  stage 03 -> jid=${prev_jid}"
    fi

    # 04 QC + variants
    if [[ "$from_stage" -le 4 ]]; then
        prev_jid="$(launch_stage 04 "${JOBS_DIR}/04_qc_variants.sh" "$isolate" "$prev_jid" \
                       "$QC_PE" "$QC_TIME" "$QC_MEM")"
        log_info "  stage 04 -> jid=${prev_jid}"
    fi
done

log_info "All isolates queued. Monitor with: qstat -u \"\$USER\""
