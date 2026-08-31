# shellcheck shell=bash
# Single source of truth for paths and defaults. Sourced by every job script
# and the driver. Do not put logic here, only assignments.

# ----- Reference read locations (project convention) -----
ONT_READS_DIR=/net/feder/vol1/project/pa_promise/jeffrey/data/reads_qc/ont
ILLUMINA_READS_DIR=/net/feder/vol1/project/pa_promise/jeffrey/data/reads_qc/illumina

# ----- Pipeline root and run output root -----
PIPELINE_ROOT=/net/feder/vol1/home/jncarey/repos/autocycler_pipeline
JOBS_DIR="${PIPELINE_ROOT}/jobs"
RUNS_DIR="${PIPELINE_ROOT}/runs"

# ----- Shared, project-wide assets (provisioned by bin/setup_shared_assets.sh) -----
SHARED_ASSETS_DIR="${PIPELINE_ROOT}/assets"
# Default Clair3 model — this fork is dedicated to pa_promise PROMISE-cohort
# isolates, currently all ONT R10.4.1 sup v4.3.0. Override per-isolate via an
# optional `clair3_model` column in samples.tsv if a future isolate differs.
CLAIR3_MODEL_DEFAULT=r1041_e82_400bps_sup_v430_bacteria_finetuned

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
KEEP_INTERMEDIATE_BAMS=true
