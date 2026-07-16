#!/usr/bin/env bash
#$ -S /bin/bash
#$ -cwd
#$ -V
#$ -j y
# qsub -N, -o, -pe, -l h_rt, -l mem_free, and -v are set by the driver.
#
# Stage 04: assembly QC + variant calling.
#   - Sniffles  (long-read SVs)
#   - freebayes (short-read SNPs/indels)
#   - Clair3    (long-read SNPs/indels)
#   - mosdepth  (coverage)
# Required env: CONFIG, ISOLATE

set -euo pipefail
source ~/miniforge3/etc/profile.d/conda.sh

: "${CONFIG:?CONFIG not set}"
: "${ISOLATE:?ISOLATE not set}"
source "$CONFIG"
source "${PIPELINE_ROOT}/bin/lib/common.sh"
parse_samples "${PIPELINE_ROOT}/config/samples.tsv"
resolve_isolate "$ISOLATE"

require_stage_done "$ISOLATE_RUN_DIR" "03"
threads="${NSLOTS:-${QC_PE}}"

REF_FASTA="${ISOLATE_RUN_DIR}/shortreads_polish/medaka_polypolish_pypolca.fasta"
REF_DIR="${ISOLATE_RUN_DIR}/shortreads_polish"
OUT_DIR="${ISOLATE_RUN_DIR}/assembly_qc_variants_check"
LONG_READS="${ISOLATE_ONT_FASTQ}"
R1="${ISOLATE_ILLUMINA_R1}"
R2="${ISOLATE_ILLUMINA_R2}"

ensure_dir "$OUT_DIR"
cd "$OUT_DIR"

# ---------------- nanopore.bam (used by sniffles, clair3, mosdepth) ----------------
if [[ ! -f nanopore.bam ]]; then
    conda activate sniffles
    module load samtools/1.22 minimap2/2.26 htslib/1.22
    log_info "[${ISOLATE}] minimap2 (aligning long reads)"
    minimap2 -a -x map-ont -t "${threads}" "${REF_FASTA}" "${LONG_READS}" \
        | samtools sort > nanopore.bam
    samtools index nanopore.bam
fi

# ---------------- Sniffles (long-read SVs) ----------------
if [[ ! -f sniffles_reference.vcf ]]; then
    conda activate sniffles
    module load samtools/1.22 minimap2/2.26 htslib/1.22 bcftools/1.22
    log_info "[${ISOLATE}] sniffles"
    sniffles -i nanopore.bam -v sniffles_reference.vcf
fi

# ---------------- freebayes (short-read SNVs/indels) ----------------
if [[ ! -f freebayes_reference.vcf ]]; then
    conda activate freebayes
    module load bcftools/1.22
    log_info "[${ISOLATE}] bwa + freebayes"
    if [[ ! -f illumina.bam ]]; then
        bwa index "${REF_FASTA}"
        bwa mem -t "${threads}" "${REF_FASTA}" "${R1}" "${R2}" \
            | samtools sort > illumina.bam
        samtools index illumina.bam
        samtools faidx "${REF_FASTA}"
    fi
    freebayes -f "${REF_FASTA}" \
        --haplotype-length 1 -m 10 -q 10 -p 1 --min-coverage 2 \
        illumina.bam \
        | bcftools view -i 'QUAL>=100' \
        | bcftools reheader -s <(printf "unknown\t%s\n" "${ISOLATE}") \
        > freebayes_reference.vcf
fi

# ---------------- Clair3 (long-read SNVs/indels) ----------------
if [[ ! -f clair3_reference.vcf ]]; then
    conda activate clair3
    module load minimap2/2.26 htslib/1.22 bcftools/1.22
    log_info "[${ISOLATE}] clair3 (conda env: clair3, model: ${ISOLATE_CLAIR3_MODEL})"
    run_clair3.sh \
        --bam_fn="${OUT_DIR}/nanopore.bam" \
        --ref_fn="${REF_FASTA}" \
        --threads="${threads}" \
        --platform="ont" \
        --model_path="${CONDA_PREFIX}/bin/models/${ISOLATE_CLAIR3_MODEL}" \
        --output="${OUT_DIR}/clair3_reference" \
        --sample_name="${ISOLATE}" \
        --include_all_ctgs \
        --haploid_precise \
        --no_phasing_for_fa \
        --enable_long_indel
    gunzip -c clair3_reference/merge_output.vcf.gz \
        | bcftools view -f 'PASS,.' \
        > clair3_reference.vcf
fi

# ---------------- mosdepth (long-read coverage) ----------------
if [[ ! -f nanopore.mosdepth.summary.txt ]]; then
    module load mosdepth/0.3.6
    log_info "[${ISOLATE}] mosdepth"
    mosdepth nanopore nanopore.bam
fi

# ---------------- cleanup intermediate BAMs/indices ----------------
if [[ "${KEEP_INTERMEDIATE_BAMS:-false}" != "true" ]]; then
    log_info "[${ISOLATE}] removing intermediate BAMs and indices"
    rm -f nanopore.bam nanopore.bam.bai
    rm -f illumina.bam illumina.bam.bai
    rm -f "${REF_FASTA}.fai" "${REF_FASTA}".amb "${REF_FASTA}".ann \
          "${REF_FASTA}".bwt "${REF_FASTA}".pac "${REF_FASTA}".sa
fi

mark_stage_done "$ISOLATE_RUN_DIR" "04"
log_info "Stage 04 (QC + variants) complete for ${ISOLATE}"
