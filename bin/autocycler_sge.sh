#!/usr/bin/env bash
set -euo pipefail

log_info()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*"; }
log_warn()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*" >&2; }
log_error()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }
log_fatal()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] FATAL: $*" >&2; }
log_recovery() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] RECOVERY: $*" >&2; }

echo_usage() {
    echo "Usage: $0 <read_fastq> [options]"
    echo
    echo "Required:"
    echo "  <read_fastq>               Input FASTQ file for long-read assembly"
    echo
    echo "General options:"
    echo "  -o, --outdir <path>         Output directory [default: current directory]"
    echo "  -t, --threads <int>         Threads per assembly job [default: 8]"
    echo "  -r, --read-type <type>      Read type: ont_r9 | ont_r10 | pacbio_clr | pacbio_hifi [default: ont_r10]"
    echo "  -k, --keep-intermediate     Keep subsampled and filtered FASTQ files after assembly"
    echo "  -w, --overwrite             Delete output directory if it exists (use with caution!)"
    echo "  -T, --max-time <duration>   SGE time limit per job [default: 8h]"
    echo "  -M, --max-mem <size>        SGE memory per job [default: 32g]"
    echo "  -C, --max-concurrent <int>  Maximum concurrent qsub jobs [default: 10]"
    echo "  -R, --resume-after-assembly Resume pipeline after assembly step (skip read filtering, subsampling, and assembly)"
    echo
    echo "Read filtering with filtlong:"
    echo "  -l, --min-length <int>      Filter out reads shorter than this length"
    echo "  -b, --target-bases <int>    Keep top reads until total base count is reached"
    echo "  -p, --keep-percent <float>  Keep best X%% of reads (e.g. 90)"
    echo
    echo "Help:"
    echo "  -h, --help                  Show this help message and exit"
}
# ------------------------------
# Parse args
# ------------------------------
reads=""
threads="8"
read_type="ont_r10"
keep_intermediate=false
max_time="8h"
max_mem="32g"
max_concurrent="10"
min_length=""
target_bases=""
keep_percent=""
outdir="."
overwrite=false
resume_after_assembly=false

while [[ $# -gt 0 ]]; do
    case "$1" in
    -o | --outdir)
        outdir="$2"
        shift 2
        ;;
    -t | --threads)
        threads="$2"
        shift 2
        ;;
    -r | --read-type)
        read_type="$2"
        shift 2
        ;;
    -R | --resume-after-assembly)
        resume_after_assembly=true
        shift
        ;;
    -k | --keep-intermediate)
        keep_intermediate=true
        shift
        ;;
    -w | --overwrite)
        overwrite=true
        shift
        ;;
    -T | --max-time)
        max_time="$2"
        shift 2
        ;;
    -M | --max-mem)
        max_mem="$2"
        shift 2
        ;;
    -C | --max-concurrent)
        max_concurrent="$2"
        shift 2
        ;;
    -l | --min-length)
        min_length="$2"
        shift 2
        ;;
    -b | --target-bases)
        target_bases="$2"
        shift 2
        ;;
    -p | --keep-percent)
        keep_percent="$2"
        shift 2
        ;;
    -h | --help)
        echo_usage
        exit 0
        ;;
    -*)
        log_error "Unknown option: $1"
        echo "Use --help to see usage." >&2
        exit 1
        ;;
    *)
        if [[ -z "$reads" ]]; then
            reads=$(realpath "$1")
        else
            log_error "Unexpected positional argument: $1"
            echo "Use --help to see usage." >&2
            exit 1
        fi
        shift
        ;;
    esac
done

# Validate required argument
if [[ -z "$reads" ]]; then
    log_error "Missing required argument: <read_fastq>"
    echo "Use --help to see usage." >&2
    exit 1
fi

if ((threads > 128)); then threads=128; fi
case $read_type in
ont_r9 | ont_r10 | pacbio_clr | pacbio_hifi) ;;
*)
    log_error "read_type must be ont_r9, ont_r10, pacbio_clr or pacbio_hifi"
    exit 1
    ;;
esac

if [[ "$overwrite" == true && "$resume_after_assembly" == true ]]; then
    log_error "Cannot use --overwrite and --resume-after-assembly together."
    echo "        Overwrite would delete assemblies/ directory needed for resume." >&2
    exit 1
fi

# Returns 0 if the assembly for a given assembler + subset index is complete.
# plassembler may produce no output file when no plasmid is present; completion
# is instead detected by "Plassembler has finished" in the log.
# All other assemblers are done when their .fasta output is non-empty.
assembly_is_done() {
    local assembler="$1" i="$2"
    if [[ "$assembler" == "plassembler" ]]; then
        local log="assemblies/${assembler}_${i}.log"
        [[ -f "$log" ]] && grep -q "Plassembler has finished" "$log"
    else
        [[ -s "assemblies/${assembler}_${i}.fasta" ]]
    fi
}

if [[ -d "$outdir" && "$overwrite" == true ]]; then
    log_warn "Output directory '$outdir' exists and will be overwritten."
    rm -rf "$outdir"
fi

mkdir -p "$outdir"
log_info "Changing to output directory: $outdir"
cd "$outdir"
mkdir -p logs

source ~/miniforge3/etc/profile.d/conda.sh
conda activate autocycler

# If all 28 assembly outputs already exist, skip the fan-out and go straight
# to the combine step (handles re-entry after partial failure or combine-only retry).
if [[ "$resume_after_assembly" == false ]]; then
    _all_done=true
    for _asm in canu flye plassembler raven myloasm miniasm necat; do
        for _i in 01 02 03 04; do
            if ! assembly_is_done "$_asm" "$_i"; then
                _all_done=false
                break 2
            fi
        done
    done
    if $_all_done; then
        log_info "All 28 assembly outputs already present; skipping to autocycler combine step."
        resume_after_assembly=true
    fi
fi

if [[ "$resume_after_assembly" == false ]]; then
    # ------------------------------
    # Optional: Filter reads with filtlong
    # ------------------------------
    if [[ -n "$min_length" || -n "$target_bases" || -n "$keep_percent" ]]; then
        log_info "Filtering reads with filtlong..."
        mkdir -p filtered

        filtlong_cmd=(filtlong)
        [[ -n "$min_length" ]] && filtlong_cmd+=(--min_length "$min_length")
        [[ -n "$target_bases" ]] && filtlong_cmd+=(--target_bases "$target_bases")
        [[ -n "$keep_percent" ]] && filtlong_cmd+=(--keep_percent "$keep_percent")

        # Strip known FASTQ extensions and gz if present
        basename_no_ext=$(basename "$reads" | sed -E 's/(\.fastq|\.fq)(\.gz)?$//')
        reads_filtered="filtered/${basename_no_ext}_filtered.fastq"

        "${filtlong_cmd[@]}" "$reads" >"$reads_filtered"
        reads="$reads_filtered"

        log_info "Filtered reads written to: $reads"
    fi

    # ------------------------------
    # Estimate genome size
    # ------------------------------
    genome_size=""
    if [[ -f logs/autocycler.stderr ]]; then
        genome_size=$(grep -oP 'Estimated genome size:\s*\K[0-9]+' logs/autocycler.stderr 2>/dev/null || true)
        [[ -n "$genome_size" ]] && log_info "Recovered genome size from previous run: $genome_size bp."
    fi
    if [[ -z "$genome_size" ]]; then
        log_info "Estimating genome size..."
        genome_size=$(autocycler helper genome_size --reads "$reads" --threads "$threads" 2>logs/autocycler.stderr)
    fi
    if [[ -z "$genome_size" ]]; then
        genome_size="6400000" # default to 6.4 Mbp for pseudomonas if estimation fails
        log_warn "Genome size estimation failed. Defaulting to $genome_size bp."
    else
        log_info "Estimated genome size: $genome_size bp."
    fi
    # ------------------------------
    # Subsample reads
    # ------------------------------
    log_info "Subsampling reads..."
    autocycler subsample \
        --reads "$reads" \
        --out_dir subsampled_reads \
        --genome_size "$genome_size" \
        2>>logs/autocycler.stderr

    # ------------------------------
    # Submit assembly jobs to SGE
    # ------------------------------
    mkdir -p assemblies/sge_logs
    rm -f assemblies/job_ids.txt

    # Maximum number of concurrent jobs to submit
    MAX_CONCURRENT_JOBS="$max_concurrent"

    log_info "Submitting assembly jobs (max concurrent: $MAX_CONCURRENT_JOBS)..."
    for assembler in canu flye plassembler raven myloasm miniasm necat; do
        for i in 01 02 03 04; do
            sample="subsampled_reads/sample_${i}.fastq"
            out_prefix="assemblies/${assembler}_${i}"
            jobname="ac_${assembler}_${i}"

            # Skip if this assembly already completed successfully.
            if assembly_is_done "$assembler" "$i"; then
                log_info "Skipping $jobname — already complete."
                continue
            fi

            # SGE resource formatting
            sge_time_val="$max_time"
            sge_mem_val="$max_mem"
            threads_val="$threads"

            case "$assembler" in
                canu)
                    sge_time_val="24h"
                    sge_mem_val="8g"
                    threads_val="8"
                    ;;
                flye|plassembler)
                    sge_time_val="2h"
                    sge_mem_val="8g"
                    threads_val="2"
                    ;;
                miniasm|raven)
                    sge_time_val="1h"
                    sge_mem_val="6g"
                    threads_val="1"
                    ;;
                myloasm)
                    sge_time_val="2h"
                    sge_mem_val="16g"
                    threads_val="1"
                    ;;
                necat)
                    sge_time_val="4h"
                    sge_mem_val="32g"
                    threads_val="1"
                    ;;
            esac
            
            # convert "8h" → "08:00:00"
            sge_time=$(printf "%02d:00:00" "${sge_time_val%h}")
            sge_mem=$(echo "$sge_mem_val" | sed 's/g/G/')

            # Create a job script with SGE directives in the header
            cat > "assemblies/sge_logs/${jobname}.sh" <<EOF
#$ -S /bin/bash
#$ -N ${jobname}
#$ -cwd
#$ -V
#$ -pe serial ${threads_val}
#$ -l h_rt=${sge_time}
#$ -l mem_free=${sge_mem}
#$ -j y
#$ -o assemblies/sge_logs/${jobname}.log

set -euo pipefail

# Initialize conda
source ~/miniforge3/etc/profile.d/conda.sh

# Activate environment
conda activate autocycler

# Run the command
autocycler helper $assembler --reads $sample --out_prefix $out_prefix --threads $threads_val --genome_size $genome_size --read_type $read_type --min_depth_rel 0.1
EOF

            chmod +x "assemblies/sge_logs/${jobname}.sh"

            # Wait if we've reached the concurrent job limit
            while true; do
                # Count only running (state "r") ac_* jobs — pending jobs do not
                # count against the cap, or the loop deadlocks when pending jobs
                # never start before the cap is reached.
                running_count=$(qstat -u "$USER" 2>/dev/null | awk '$5 == "r"' | grep -c " ac_" || true)

                if (( running_count < MAX_CONCURRENT_JOBS )); then
                    break
                fi
                
                log_info "Waiting... ($running_count/$MAX_CONCURRENT_JOBS jobs running)"
                sleep 30
            done

            # Submit job via qsub - just pass the script
            qsub_out=$(qsub "assemblies/sge_logs/${jobname}.sh")
            
            # Extract job ID: Usually "Your job 12345 ("name") has been submitted"
            jobid=$(echo "$qsub_out" | grep -oP 'Your job \K[0-9]+')

            if [[ -n "$jobid" ]]; then
                log_info "Submitted $jobname → JobID=$jobid (running: $((running_count + 1))/$MAX_CONCURRENT_JOBS)"
                echo "$jobid" >> assemblies/job_ids.txt
            else
                log_error "Failed to get job ID for $jobname"
                exit 1
            fi
        done
    done

    # ------------------------------
    # Wait for all jobs to complete
    # ------------------------------
    log_info "Waiting for assembly jobs to complete..."
    sleep 10

    mapfile -t job_ids < assemblies/job_ids.txt
    start_time=$(date +%s)

    while true; do
        sleep 60

        still_running=()
        for jobid in "${job_ids[@]}"; do
            # qstat returns 0 if job is active
            if qstat -j "$jobid" &>/dev/null; then
                still_running+=("$jobid")
            fi
        done

        if (( ${#still_running[@]} == 0 )); then
            log_info "All jobs have exited qstat. Checking final statuses..."
            break
        fi

        elapsed=$(( $(date +%s) - start_time ))
        minutes=$(( elapsed / 60 ))
        seconds=$(( elapsed % 60 ))
        log_info "${#still_running[@]} job(s) still running after ${minutes}m ${seconds}s: ${still_running[*]}"
    done

    # ------------------------------
    # Verify all assembly outputs are present
    # ------------------------------
    missing_assemblies=()
    for assembler in canu flye plassembler raven myloasm miniasm necat; do
        for i in 01 02 03 04; do
            if ! assembly_is_done "$assembler" "$i"; then
                missing_assemblies+=("${assembler}_${i}")
            fi
        done
    done

    if (( ${#missing_assemblies[@]} > 0 )); then
        log_fatal "${#missing_assemblies[@]} assembly output(s) missing or incomplete:"
        printf "  - %s\n" "${missing_assemblies[@]}" >&2
        echo "" >&2
        log_recovery "Check per-job logs in assemblies/sge_logs/ for the cause."
        log_recovery "Fix the issue, then re-run stage 00 — completed assemblies will be skipped."
        exit 1
    fi

    log_info "All assembly outputs verified."
else
    log_info "Resuming pipeline after assembly."
    if [[ ! -d assemblies ]]; then
        log_error "Cannot resume: assemblies/ directory not found."
        exit 1
    fi
    
    # Load genome_size from previous run
    if [[ -f logs/autocycler.stderr ]]; then
        genome_size=$(grep -oP 'Estimated genome size:\s*\K[0-9]+' logs/autocycler.stderr 2>/dev/null || echo "")
    fi
    
    if [[ -z "$genome_size" ]]; then
        log_warn "Could not retrieve genome_size from previous run. This may cause issues if needed."
    fi
fi

# ------------------------------
# Adjust output weights
# ------------------------------
log_info "Adjusting assembly outputs..."
shopt -s nullglob
for f in assemblies/plassembler*.gfa; do
    sed -i 's/circular=True/circular=True Autocycler_cluster_weight=3/' "$f"
done
for f in assemblies/canu*.fasta assemblies/flye*.fasta; do
    sed -i 's/^>.*$/& Autocycler_consensus_weight=2/' "$f"
done
shopt -u nullglob

# ------------------------------
# Cleanup and continue pipeline
# ------------------------------
if [[ "$keep_intermediate" = false ]]; then
    log_info "Removing intermediate reads..."
    rm -rf subsampled_reads/*.fastq
    rm -f filtered/*.fastq 2>/dev/null || true
fi

log_info "Running Autocycler compression, clustering, and resolution..."
autocycler compress -i assemblies -a autocycler_out -t "$threads" 2>>logs/autocycler.stderr

autocycler cluster -a autocycler_out 2>>logs/autocycler.stderr

for c in autocycler_out/clustering/qc_pass/cluster_*; do
    autocycler trim -c "$c" -t "$threads" 2>>logs/autocycler.stderr
    autocycler resolve -c "$c" 2>>logs/autocycler.stderr
done

autocycler combine \
    -a autocycler_out \
    -i autocycler_out/clustering/qc_pass/cluster_*/5_final.gfa \
    2>>logs/autocycler.stderr

log_info "Autocycler pipeline completed successfully."

