# shellcheck shell=bash
# Shared helpers for the autocycler production pipeline. Source this from the
# driver or, after `source ~/.bashrc`, from a job script.
#
# Provides:
#   load_config <config_path>
#   parse_samples <samples.tsv>           -> populates SAMPLE_ROWS array
#   resolve_isolate <isolate>             -> sets ISOLATE_* vars from a TSV row
#                                            (or convention defaults)
#   isolate_run_dir <isolate>             -> echoes the run dir
#   ensure_dir <path>...                  -> mkdir -p with a one-line check

set -euo pipefail

# ---------------- logging ----------------
log_info()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*"; }
log_warn()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*" >&2; }
log_error()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }
log_fatal()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] FATAL: $*" >&2; }
log_recovery() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] RECOVERY: $*" >&2; }

# ---------------- config ----------------
load_config() {
    local cfg="${1:?load_config requires a config path}"
    if [[ ! -f "$cfg" ]]; then
        log_error "config not found: $cfg"
        return 1
    fi
    # shellcheck disable=SC1090
    source "$cfg"
}

ensure_dir() {
    local d
    for d in "$@"; do
        mkdir -p "$d"
    done
}

stage_sentinel() { echo "${1}/.stage_${2}.done"; }

mark_stage_done() { touch "$(stage_sentinel "$1" "$2")"; }

require_stage_done() {
    local sentinel
    sentinel="$(stage_sentinel "$1" "$2")"
    if [[ ! -f "$sentinel" ]]; then
        log_error "Stage ${2} did not complete successfully (missing ${sentinel}). Aborting."
        exit 1
    fi
}

isolate_run_dir() {
    local isolate="${1:?isolate required}"
    echo "${RUNS_DIR}/${isolate}"
}

# ---------------- samplesheet ----------------
# Reads samples.tsv into the global associative array SAMPLE_BY_ISOLATE keyed
# by isolate, value = a tab-joined string of column=value pairs.
# Required column: isolate. Optional columns: read_type, medaka_model,
# clair3_model, ont_fastq, illumina_r1, illumina_r2.
declare -gA SAMPLE_BY_ISOLATE=()
declare -ga SAMPLE_ORDER=()
declare -ga SAMPLE_COLUMNS=()

parse_samples() {
    local tsv="${1:?samples.tsv required}"
    if [[ ! -f "$tsv" ]]; then
        log_error "samples.tsv not found: $tsv"
        return 1
    fi
    SAMPLE_BY_ISOLATE=()
    SAMPLE_ORDER=()
    SAMPLE_COLUMNS=()

    local header
    IFS=$'\t' read -r -a SAMPLE_COLUMNS < <(head -n1 "$tsv")
    if [[ "${SAMPLE_COLUMNS[0]}" != "isolate" ]]; then
        log_error "samples.tsv first column must be 'isolate' (got '${SAMPLE_COLUMNS[0]}')"
        return 1
    fi

    local lineno=1
    while IFS= read -r line; do
        ((lineno++)) || true
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^# ]] && continue
        IFS=$'\t' read -r -a fields <<<"$line"
        if (( ${#fields[@]} != ${#SAMPLE_COLUMNS[@]} )); then
            log_error "samples.tsv line $lineno: expected ${#SAMPLE_COLUMNS[@]} columns, got ${#fields[@]}"
            return 1
        fi
        local isolate="${fields[0]}"
        local kv_pairs=""
        local i
        for (( i=0; i<${#SAMPLE_COLUMNS[@]}; i++ )); do
            kv_pairs+="${SAMPLE_COLUMNS[$i]}=${fields[$i]}"$'\t'
        done
        SAMPLE_BY_ISOLATE["$isolate"]="$kv_pairs"
        SAMPLE_ORDER+=("$isolate")
    done < <(tail -n +2 "$tsv")
}

# resolve_isolate <isolate>
# After call, the following vars are set in the caller's scope:
#   ISOLATE, ISOLATE_READ_TYPE, ISOLATE_MEDAKA_MODEL, ISOLATE_CLAIR3_MODEL,
#   ISOLATE_ONT_FASTQ, ISOLATE_ILLUMINA_R1, ISOLATE_ILLUMINA_R2, ISOLATE_RUN_DIR
# Missing optional fields fall back to config defaults / convention paths.
resolve_isolate() {
    local isolate="${1:?isolate required}"
    if [[ -z "${SAMPLE_BY_ISOLATE[$isolate]+x}" ]]; then
        log_error "isolate '$isolate' not found in samplesheet"
        return 1
    fi

    ISOLATE="$isolate"
    ISOLATE_READ_TYPE=""
    ISOLATE_MEDAKA_MODEL=""
    ISOLATE_CLAIR3_MODEL=""
    ISOLATE_ONT_FASTQ=""
    ISOLATE_ILLUMINA_R1=""
    ISOLATE_ILLUMINA_R2=""

    local row="${SAMPLE_BY_ISOLATE[$isolate]}"
    local pair key val
    while IFS= read -r pair; do
        [[ -z "$pair" ]] && continue
        key="${pair%%=*}"
        val="${pair#*=}"
        case "$key" in
            isolate)       ;;  # already handled
            read_type)     ISOLATE_READ_TYPE="$val" ;;
            medaka_model)  ISOLATE_MEDAKA_MODEL="$val" ;;
            clair3_model)  ISOLATE_CLAIR3_MODEL="$val" ;;
            ont_fastq)     ISOLATE_ONT_FASTQ="$val" ;;
            illumina_r1)   ISOLATE_ILLUMINA_R1="$val" ;;
            illumina_r2)   ISOLATE_ILLUMINA_R2="$val" ;;
            *) log_warn "unknown samples.tsv column ignored: $key" ;;
        esac
    done < <(tr '\t' '\n' <<<"$row")

    # Defaults / convention fallbacks
    : "${ISOLATE_READ_TYPE:=ont_r9}"
    : "${ISOLATE_CLAIR3_MODEL:=${CLAIR3_MODEL_DEFAULT:?CLAIR3_MODEL_DEFAULT not set in config}}"
    : "${ISOLATE_ONT_FASTQ:=${ONT_READS_DIR:?ONT_READS_DIR not set in config}/${isolate}.fastq.gz}"
    : "${ISOLATE_ILLUMINA_R1:=${ILLUMINA_READS_DIR:?ILLUMINA_READS_DIR not set in config}/${isolate}_1.fastq.gz}"
    : "${ISOLATE_ILLUMINA_R2:=${ILLUMINA_READS_DIR}/${isolate}_2.fastq.gz}"

    if [[ -z "$ISOLATE_MEDAKA_MODEL" ]]; then
        log_error "isolate '$isolate' has no medaka_model in samples.tsv"
        return 1
    fi

    ISOLATE_RUN_DIR="$(isolate_run_dir "$isolate")"
}

# Count running (state "r") SGE assembler jobs (name prefix "ac_").
# Pending jobs are excluded; counting them caused a deadlock where the cap was
# hit by pending jobs that never ran before new submissions were allowed.
count_global_assembler_jobs() {
    qstat -u "$USER" 2>/dev/null | awk 'NR>2 && $3 ~ /^ac_/ && $5 == "r"' | wc -l
}
