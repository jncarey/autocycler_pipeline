# Autocycler — Driver pipeline

Multi-isolate bacterial genome assembly pipeline for *Pseudomonas* isolates using [Autocycler](https://github.com/rrwick/Autocycler).

The pipeline is adapted from the [Autocycler example pipeline](https://github.com/rrwick/Autocycler/tree/main/pipelines) and customized for our dataset and SGE cluster environment. 

## Prerequisites

- SGE compute cluster
- Conda/mamba (e.g. [miniforge](https://github.com/conda-forge/miniforge)) installed under your account
- The six conda environments below
- Plassembler's reference database (`bin/setup_shared_assets.sh`)
- Reads already QC'd — **this pipeline does no read filtering/trimming of its own** (confirmed by
  reading every job script; there is no fastp/filtlong/porechop call anywhere in `jobs/` or `bin/`).
  Point `ONT_READS_DIR`/`ILLUMINA_READS_DIR` (or the per-isolate override columns) at reads that have
  already been QC'd elsewhere. What QC to use isn't prescribed by this repo — it depends on your
  reads' chemistry/platform (see the pa_promise project's `bin/Snakefile` for one example: fastp
  defaults for Illumina, `filtlong --min_length 1000` for ONT).

None of this is automated by a single install script (there's no `environment.yml` in this repo) —
build each environment by hand as below.

### Building the conda environments

| Env | Used by | Build command |
|---|---|---|
| `pypolca` | stage 03 | `mamba create -n pypolca -c conda-forge -c bioconda bwa polypolish pypolca -y` |
| `medaka` | stage 02 | `mamba create -n medaka -c conda-forge -c bioconda medaka -y` |
| `freebayes` | stage 04 | `mamba create -n freebayes -c conda-forge -c bioconda freebayes bwa samtools -y` (samtools included directly — stage 04's freebayes block doesn't reliably get it from an earlier `module load` if that step is ever skipped on a resume) |
| `sniffles` | stage 04 | `mamba create -n sniffles -c conda-forge -c bioconda sniffles -y` |
| `clair3` | stage 04 | `mamba create -n clair3 -c conda-forge -c bioconda clair3 -y` — pre-trained models (e.g. `r941_prom_sup_g5014`) are bundled directly under `${CONDA_PREFIX}/bin/models/`; no separate download needed |
| `autocycler` | stages 00, 01 | `mamba create -n autocycler -c conda-forge -c bioconda autocycler canu flye miniasm minipolish myloasm necat plassembler raven-assembler dnaapler filtlong -y` |

The package list per environment was reverse-engineered from reading which tool each `conda activate
<env>` block in `jobs/*.sh` actually invokes afterward — cross-checked against Autocycler's own
[published environment.yml](https://github.com/rrwick/Autocycler/tree/main/pipelines/Conda_environment_file_by_Ryan_Wick)
and [wiki](https://github.com/rrwick/Autocycler/wiki/Software-requirements-and-installation) for the
assembler list, and against [Clair3's README](https://github.com/HKU-BAL/Clair3) for model naming.
Verify each environment after creating it (e.g. `mamba run -n <env> <tool> --version` or `-h`/`-help`
— flags aren't consistent across these tools).

### `bin/setup_shared_assets.sh`

Plassembler (in the `autocycler` env) needs a reference database that isn't installed by the conda
package itself. Run once, after creating the `autocycler` environment:

```bash
bin/setup_shared_assets.sh
```

This downloads the database to `$CONDA_PREFIX/plassembler_db` (plassembler's own documented default
fallback location — anything that does `conda activate autocycler` finds it automatically, no
further configuration needed). Without this, stage 00's plassembler jobs fail immediately with
`Error: No Plassembler database found.`

### First-time config after cloning/forking

A fresh clone still has the previous user's absolute paths baked into
`config/pipeline.config.sh` (`PIPELINE_ROOT`, `ONT_READS_DIR`, `ILLUMINA_READS_DIR`) and their
isolates in `config/samples.tsv`. **Check and update all of these before running anything** — a
`--dry-run` that still shows `qsub` commands pointing at someone else's `PIPELINE_ROOT` directory
means you're about to submit jobs against their live deployment, not your own clone. Same for
`CLAIR3_MODEL_DEFAULT` if your isolates use different basecall chemistry than whoever you cloned
from (identify chemistry from the `basecall_model_version_id=` field in a raw ONT FASTQ header, and
match against `mamba run -n clair3 -- run_clair3.sh` / medaka's model list).

### Isolate ID naming

SGE job names (`qsub -N`) can't start with a digit. `run_pipeline.sh` already guards against this by
prefixing every job name with `iso_`, so isolate IDs starting with a number (e.g. `009-007_V1A_12`)
work fine — but this is worth knowing if you ever see `qsub`'s "not a valid object name" error
elsewhere in a custom script that builds its own job name from an isolate ID directly.

## Layout

```
autocycler/
├── config/
│   ├── pipeline.config.sh      # paths, defaults, resource caps
│   └── samples.tsv             # isolate, read_type, medaka_model
├── bin/
│   ├── run_pipeline.sh         # driver — qsubs the stage DAG per isolate
│   ├── autocycler_sge.sh       # stage-00 implementation
│   └── lib/common.sh           # config loader + samplesheet parser
├── jobs/
│   ├── 00_assemble.sh          # filter / subsample / 7×4 assemblies / autocycler combine
│   ├── 01_dnaapler.sh          # reorient circular contigs
│   ├── 02_medaka.sh            # long-read polish
│   ├── 03_shortreads_polish.sh # Polypolish + pypolca
│   └── 04_qc_variants.sh       # Sniffles + freebayes + Clair3 + mosdepth
└── runs/<ISOLATE>/             # all per-isolate outputs (gitignored)
```

## Configuration

### `config/samples.tsv`

Tab-separated, one isolate per row. Required columns: `isolate`, `read_type`, `medaka_model`.

```
isolate     read_type   medaka_model
IA04pB3A9   ont_r9      r941_min_hac_g507
```

ONT and Illumina paths are auto-derived from `${ONT_READS_DIR}/<isolate>.fastq.gz` and `${ILLUMINA_READS_DIR}/<isolate>_{1,2}.fastq.gz`. Optional columns `clair3_model`, `ont_fastq`, `illumina_r1`, `illumina_r2` override the defaults when present.

### `config/pipeline.config.sh`

Global paths, thread counts, resource caps, and `KEEP_INTERMEDIATE_BAMS`. Edit here to change concurrency (`GLOBAL_ASSEMBLY_MAX_CONCURRENT=20`) or resource limits.

## Run

```
Usage: bin/run_pipeline.sh [options]

Options:
  --samples <tsv>          Samplesheet (default: config/samples.tsv)
  --isolate <id[,id]>      Run only the listed isolate(s); comma-separated
  --from <00|01|02|03|04>  Resume: skip stages before this one
  --dry-run                Print qsub commands instead of executing
  -h, --help               Show this help
```

Examples:

```bash
bin/run_pipeline.sh                                    # all isolates
bin/run_pipeline.sh --isolate IA04pB3A9                # one isolate
bin/run_pipeline.sh --isolate IA04pB3A9,IA04pB3A10     # subset
bin/run_pipeline.sh --isolate IA04pB3A9 --from 02      # resume from stage 02
bin/run_pipeline.sh --dry-run                          # preview qsub commands
```

The driver queues stages 00–04 in dependency order via `qsub -hold_jid` and exits immediately after queuing. Monitor with:

```bash
qstat -u "$USER"
```

Per-isolate logs land in `runs/<ISOLATE>/logs/`. All log lines are timestamped: `[YYYY-MM-DD HH:MM:SS] LEVEL: message`.

## Failure recovery

### Stage 00 assembler failures

Stage 00 fans out 28 inner SGE jobs (7 assemblers × 4 subsets). If some fail, the stage logs a `FATAL` message listing the incomplete `assembler_subset` entries and exits non-zero.

**Recovery steps:**

1. Check the relevant log: `runs/<ISOLATE>/assemblies/sge_logs/ac_<assembler>_<subset>.log`
2. Fix the root cause (e.g. raise per-assembler memory in `bin/autocycler_sge.sh`)
3. Re-run stage 00 — assemblies that already completed are skipped automatically:

```bash
bin/run_pipeline.sh --isolate IA04pB3A9 --from 00
```

If all 28 outputs already exist (e.g. the combine step failed on a prior run), the fan-out is skipped and only the combine step re-runs.

**Success signals per assembler:**
- All assemblers except plassembler: non-empty `assemblies/<assembler>_<N>.fasta`
- plassembler: `"Plassembler has finished"` in `assemblies/plassembler_<N>.log` (no FASTA expected when no plasmid is present)

## Outputs

```
runs/<ISOLATE>/
├── logs/
│   ├── 00.log … 04.log              # SGE stage job output (stdout+stderr merged)
│   ├── autocycler.stderr            # autocycler tool stderr (stage 00)
│   └── dnaapler.stderr              # dnaapler + gfa2fasta stderr (stage 01)
├── subsampled_reads/
├── assemblies/
├── autocycler_out/
│   └── consensus_assembly.gfa
├── dnaapler/
│   └── dnaapler_reoriented.fasta
├── medaka/
│   └── consensus.fasta
├── shortreads_polish/
│   └── medaka_polypolish_pypolca.fasta   # final polished assembly
└── assembly_qc_variants_check/
    ├── sniffles_reference.vcf
    ├── freebayes_reference.vcf
    ├── clair3_reference.vcf
    └── nanopore.mosdepth.*
```
