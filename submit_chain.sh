#!/bin/bash
# ============================================================
#  submit_chain.sh
#
#  Automatically chains multiple Slurm jobs so that each run
#  starts only after the previous one finishes successfully.
#
#  Designed for simulations where you run the same executable
#  multiple times with different input files (e.g. different
#  parameters, CFL values, iteration counts, mesh refinements).
#
#  HOW TO USE:
#  -----------
#  1. Make one copy of your input file per run and edit the
#     parameters you want to change in each copy:
#
#       cp input.in input_run1.in    # edit parameters for run 1
#       cp input.in input_run2.in    # edit parameters for run 2
#       cp input.in input_run3.in    # edit parameters for run 3
#
#  2. Submit the entire chain with one command:
#
#       bash submit_chain.sh input_run1.in input_run2.in input_run3.in
#
#  That's it. Each job is automatically queued to start after
#  the previous one finishes. If any job fails, all downstream
#  jobs are cancelled automatically (saves allocation credits).
#
#  MONITOR JOBS:  squeue -u $USER
#  CANCEL ALL:    scancel --user=$USER
# ============================================================

# ── Name of your Slurm job script ──────────────────────────
# Change this if your job script has a different name
JOB_SCRIPT="run.sh"

# ── Name of the environment variable your job script reads ─
# run.sh checks this variable to know which input file to use.
# Change this to match whatever variable name you use in run.sh
INPUT_FILE_VAR="INPUT_FILE_STAGE"

# ============================================================

# Show usage if no arguments are given
if [ "$#" -lt 1 ]; then
    echo ""
    echo "  Usage: bash submit_chain.sh input_run1.in input_run2.in input_run3.in ..."
    echo ""
    echo "  Each argument is an input file with the settings for that run."
    echo "  Jobs are chained: each run starts only after the previous one"
    echo "  finishes successfully (exit code 0)."
    echo ""
    exit 1
fi

# Check that the job script exists before doing anything
if [ ! -f "$JOB_SCRIPT" ]; then
    echo "ERROR: Job script '$JOB_SCRIPT' not found in $(pwd)."
    echo "Make sure '$JOB_SCRIPT' is in the same directory as this script."
    exit 1
fi

# Check that all input files exist before submitting anything
# (better to catch a typo now than after 3 jobs have already run)
for INPUT_FILE in "$@"; do
    if [ ! -f "$INPUT_FILE" ]; then
        echo "ERROR: Input file '$INPUT_FILE' not found. Please check the filename."
        exit 1
    fi
done

echo ""
echo "======================================"
echo "  Submitting job chain"
echo "  Working dir : $(pwd)"
echo "  Job script  : $JOB_SCRIPT"
echo "  Total runs  : $#"
echo "======================================"
echo ""

PREV_JOB_ID=""   # tracks the job ID of the previous submission
RUN_NUMBER=0     # counter for display purposes

for INPUT_FILE in "$@"; do
    RUN_NUMBER=$(( RUN_NUMBER + 1 ))

    if [ -z "$PREV_JOB_ID" ]; then
        # ── First job: no dependency, starts immediately ────
        JOB_ID=$(sbatch \
            --export=ALL,${INPUT_FILE_VAR}="$(pwd)/$INPUT_FILE" \
            "$JOB_SCRIPT" | awk '{print $4}')
        echo "  Run $RUN_NUMBER → Job ID: $JOB_ID  |  Input: $INPUT_FILE  |  Starts: immediately"
    else
        # ── Subsequent jobs: wait for the previous job to  ─
        # ── finish with exit code 0 (afterok).             ─
        # ── If the previous job failed, this one is        ─
        # ── automatically cancelled by Slurm.              ─
        JOB_ID=$(sbatch \
            --dependency=afterok:$PREV_JOB_ID \
            --export=ALL,${INPUT_FILE_VAR}="$(pwd)/$INPUT_FILE" \
            "$JOB_SCRIPT" | awk '{print $4}')
        echo "  Run $RUN_NUMBER → Job ID: $JOB_ID  |  Input: $INPUT_FILE  |  Waiting on: Job $PREV_JOB_ID"
    fi

    # Check that sbatch actually returned a job ID
    # (empty means submission failed)
    if [ -z "$JOB_ID" ]; then
        echo ""
        echo "ERROR: Submission failed for '$INPUT_FILE'. Stopping."
        echo "Check that '$JOB_SCRIPT' is valid and that sbatch is available."
        exit 1
    fi

    # Store this job's ID so the next job can depend on it
    PREV_JOB_ID=$JOB_ID
done

echo ""
echo "======================================"
echo "  All $RUN_NUMBER jobs submitted!"
echo "  Monitor:    squeue -u $USER"
echo "  Cancel all: scancel --user=$USER"
echo "======================================"
echo ""
