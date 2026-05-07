# shellcheck shell=bash
# Single source of truth for paths and defaults. Sourced by every job script
# and the driver. Do not put logic here, only assignments.

# ----- Reference read locations (project convention) -----
ONT_READS_DIR=/net/feder/vol1/project/spatially_sampled_Pa/data/reference_reads/ont/fastq_qc
ILLUMINA_READS_DIR=/net/feder/vol1/project/spatially_sampled_Pa/data/reference_reads/illumina/fastq_qc

# ----- Pipeline root and run output root -----
PIPELINE_ROOT=/net/feder/vol1/project/pseudomonas_selection/autocycler
JOBS_DIR="${PIPELINE_ROOT}/jobs"
RUNS_DIR="${PIPELINE_ROOT}/runs"

# ----- Shared, project-wide assets (provisioned by bin/setup_shared_assets.sh) -----
SHARED_ASSETS_DIR="${PIPELINE_ROOT}/assets"
# Default Clair3 model — all current isolates are ONT R9. Override per-isolate
# via an optional `clair3_model` column in samples.tsv.
CLAIR3_MODEL_DEFAULT=r941_prom_sup_g5014

# ----- Stage 00 (assembly) resource defaults — preserve dev values -----
ASSEMBLY_THREADS=8
ASSEMBLY_MAX_TIME=8h
ASSEMBLY_MAX_MEM=32g
ASSEMBLY_MAX_CONCURRENT=10            # per-isolate cap, passed to autocycler_sge.sh -C
GLOBAL_ASSEMBLY_MAX_CONCURRENT=20     # cluster-wide cap across isolates, enforced by driver

# ----- Stage 01-04 SGE PE slot counts (preserve dev values) -----
DNAAPLER_PE=4
DNAAPLER_TIME=12:00:00
DNAAPLER_MEM=4G

MEDAKA_PE=4
MEDAKA_TIME=12:00:00
MEDAKA_MEM=8G

POLISH_PE=10
POLISH_TIME=12:00:00
POLISH_MEM=2G

QC_PE=8
QC_TIME=12:00:00
QC_MEM=4G

# ----- Cleanup policy -----
# When false, intermediate BAMs / index files are removed after stage 04.
KEEP_INTERMEDIATE_BAMS=false
