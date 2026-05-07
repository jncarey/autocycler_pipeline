# Autocycler — Driver pipeline

Multi-isolate bacterial genome assembly pipeline for *Pseudomonas* isolates using [Autocycler](https://github.com/rrwick/Autocycler).

The pipeline is adapted from the [Autocycler example pipeline](https://github.com/rrwick/Autocycler/tree/main/pipelines) and customized for our dataset and SGE cluster environment. 

## Prerequisites

- SGE compute cluster
- The following conda environments must exist on the cluster nodes:

| Env | Used by |
|---|---|
| `autocycler` | stages 00, 01 |
| `medaka` | stage 02 |
| `pypolca` | stage 03 |
| `sniffles` | stage 04 |
| `freebayes` | stage 04 |
| `clair3` | stage 04 |

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
