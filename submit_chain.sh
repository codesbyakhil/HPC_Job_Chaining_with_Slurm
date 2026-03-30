#!/bin/bash
# ============================================================
#  submit_chain.sh  —  Chain Slurm simulation jobs with backup
#
#  WHAT THIS SCRIPT DOES:
#  ----------------------
#  Submits multiple simulation runs as a Slurm job chain.
#  Each run starts only after the previous one finishes
#  successfully (exit code 0). If any job fails, all
#  downstream jobs are automatically cancelled by Slurm.
#
#  After each simulation job, an optional lightweight backup
#  job runs on a CPU node. It copies your output files to
#  timestamped backup directories so you never lose results    
#  between runs.
#
#  Chain structure per run:
#
#    sim_job_1 → backup_job_1 → sim_job_2 → backup_job_2 → ...
#
#  HOW TO USE:
#  -----------
#  1. Edit the CONFIGURATION block below to match your setup:
#
#       JOB_SCRIPT        — name of your Slurm job script (e.g. run.sh)
#       INPUT_FILE_VAR    — environment variable your job script reads
#                           to know which input file to use
#       BACKUP_PARTITION  — Slurm partition for the backup job
#                           (use a CPU partition, not your GPU partition)
#       BACKUP_ENABLED    — set to "yes" to run backup jobs,
#                           "no" to skip them and just chain sims
#
#  2. Configure what the backup job copies in the
#     BACKUP SOURCES AND DESTINATIONS block below.
#
#  3. Prepare one input file per run:
#
#       cp flow.in flow_run1.in    # edit CFL / niter for run 1
#       cp flow.in flow_run2.in    # edit CFL / niter for run 2
#       cp flow.in flow_run3.in    # edit CFL / niter for run 3
#
#  4. Submit the chain:
#
#       bash submit_chain.sh flow_run1.in flow_run2.in flow_run3.in
#
#  MONITOR:    squeue -u $USER
#  CANCEL ALL: scancel --user=$USER
#
# ============================================================


# ============================================================
#  CONFIGURATION — edit this block to match your cluster/code
# ============================================================

# Name of your Slurm job script
JOB_SCRIPT="run.sh"

# Environment variable that your job script reads to find the
# input file. In run.sh this is checked as $FLOW_IN_STAGE.
# Change it if your job script uses a different variable name.
INPUT_FILE_VAR="FLOW_IN_STAGE"

# Slurm partition for the backup job.
# The backup job is pure CPU work (just file copies), so use
# a CPU partition here to avoid wasting GPU allocation.
# Run:  sinfo -o "%P %a %l %D %t"  to see available partitions.
BACKUP_PARTITION="standard"

# Set to "yes" to run a backup job after each simulation.
# Set to "no" to only chain the simulation jobs (no backups).
BACKUP_ENABLED="yes"

# ============================================================
#  BACKUP SOURCES AND DESTINATIONS
#  Each entry is a pair:
#    SRC  — directory containing files to back up
#    DST  — directory where timestamped copies will be stored
#    PAT  — glob pattern selecting which files to copy
#
#  Add, remove, or edit entries to match your output structure.
#  You can have as many pairs as you need.
# ============================================================

# Number of source/destination pairs
NUM_BACKUP_PAIRS=2

# Pair 1: restart files
BACKUP_SRC_1="restart_files"
BACKUP_DST_1="back_restart"
BACKUP_PAT_1="restart*.in"

# Pair 2: Tecplot output files
BACKUP_SRC_2="tecplot_files"
BACKUP_DST_2="back_tecplot"
BACKUP_PAT_2="*.dat"

# To add a third pair, uncomment and fill in:
# NUM_BACKUP_PAIRS=3
# BACKUP_SRC_3="your_output_dir"
# BACKUP_DST_3="back_your_output_dir"
# BACKUP_PAT_3="*.your_extension"

# ============================================================
#  END OF CONFIGURATION — no edits needed below this line
# ============================================================


# ── Show usage if no arguments are given ───────────────────
if [ "$#" -lt 1 ]; then
    echo ""
    echo "  Usage: bash submit_chain.sh input_run1.in input_run2.in ..."
    echo ""
    echo "  Each argument is an input file for that run."
    echo "  Jobs are chained: each run starts only after the previous"
    echo "  one finishes successfully (exit code 0)."
    echo ""
    exit 1
fi

# ── Verify the job script exists ───────────────────────────
if [ ! -f "$JOB_SCRIPT" ]; then
    echo "ERROR: Job script '$JOB_SCRIPT' not found in $(pwd)."
    echo "Set JOB_SCRIPT at the top of this file to the correct name."
    exit 1
fi

# ── Verify all input files exist before submitting anything ─
# (better to catch a typo now than after several jobs have run)
for INPUT_FILE in "$@"; do
    if [ ! -f "$INPUT_FILE" ]; then
        echo "ERROR: Input file '$INPUT_FILE' not found."
        echo "Please check the filename and try again."
        exit 1
    fi
done

WORK_DIR="$(pwd)"

echo ""
echo "======================================"
echo "  Submitting job chain"
echo "  Working dir  : $WORK_DIR"
echo "  Job script   : $JOB_SCRIPT"
echo "  Backup       : $BACKUP_ENABLED"
if [ "$BACKUP_ENABLED" = "yes" ]; then
    echo "  Backup part  : $BACKUP_PARTITION"
fi
echo "  Total runs   : $#"
echo "======================================"
echo ""

PREV_JOB_ID=""   # job ID of the most recently submitted job
                 # (sim or backup) — the next sim waits on this
RUN_NUMBER=0

for INPUT_FILE in "$@"; do
    RUN_NUMBER=$(( RUN_NUMBER + 1 ))
    RUN_LABEL="$(basename "${INPUT_FILE%.*}")"   # filename without extension

    # ── Submit simulation job ───────────────────────────────
    if [ -z "$PREV_JOB_ID" ]; then
        # First job: no dependency, starts as soon as resources
        # are available
        SIM_JOB_ID=$(sbatch \
            --export=ALL,${INPUT_FILE_VAR}="${WORK_DIR}/${INPUT_FILE}" \
            "$JOB_SCRIPT" | awk '{print $4}')
        echo "  Run $RUN_NUMBER → Sim  Job ID: $SIM_JOB_ID  |  Input: $INPUT_FILE  |  Starts: immediately"
    else
        # Subsequent jobs: start only after the previous job
        # (sim or backup) exits with code 0.
        # afterok means Slurm cancels this job automatically
        # if the dependency fails.
        SIM_JOB_ID=$(sbatch \
            --dependency=afterok:$PREV_JOB_ID \
            --export=ALL,${INPUT_FILE_VAR}="${WORK_DIR}/${INPUT_FILE}" \
            "$JOB_SCRIPT" | awk '{print $4}')
        echo "  Run $RUN_NUMBER → Sim  Job ID: $SIM_JOB_ID  |  Input: $INPUT_FILE  |  Waiting on: Job $PREV_JOB_ID"
    fi

    # Check that sbatch returned a job ID (empty = submission failed)
    if [ -z "$SIM_JOB_ID" ]; then
        echo ""
        echo "ERROR: Simulation job submission failed for '$INPUT_FILE'. Stopping."
        echo "Check that '$JOB_SCRIPT' is valid and sbatch is available."
        exit 1
    fi

    # ── Submit backup job (optional) ───────────────────────
    # The backup job runs on a CPU node after the sim succeeds.
    # It copies each configured source directory to a timestamped
    # backup destination. Originals are never touched (cp, not mv).
    #
    # Implementation notes:
    #   - bash -c '...' is used explicitly because --wrap alone
    #     may invoke /bin/sh on some clusters, which does not
    #     support pipefail or other bashisms.
    #   - Variables without backslash ($WORK_DIR, $SIM_JOB_ID,
    #     $NUM_BACKUP_PAIRS, etc.) are expanded NOW at submit
    #     time by this script.
    #   - Variables with backslash (\$TIMESTAMP, \$FILE, etc.)
    #     are expanded LATER at run time on the compute node.

    if [ "$BACKUP_ENABLED" = "yes" ]; then

        # ── Build the backup command string dynamically ─────
        # We loop over the configured pairs here (at submit time)
        # and emit one shell block per pair into the --wrap string.
        # This avoids passing arrays through the Slurm environment.

        BACKUP_PAIRS_CODE=""
        for (( P=1; P<=NUM_BACKUP_PAIRS; P++ )); do
            # Dereference the per-pair variables by name
            SRC_VAR="BACKUP_SRC_${P}"
            DST_VAR="BACKUP_DST_${P}"
            PAT_VAR="BACKUP_PAT_${P}"
            SRC="${WORK_DIR}/${!SRC_VAR}"
            DST="${WORK_DIR}/${!DST_VAR}"
            PAT="${!PAT_VAR}"

            BACKUP_PAIRS_CODE="${BACKUP_PAIRS_CODE}
            echo \"\"
            echo \"── Backup pair ${P}: ${!SRC_VAR} → ${!DST_VAR} (pattern: ${PAT}) ──\"
            if [ ! -d \"${SRC}\" ]; then
                echo \"WARNING: Source directory '${SRC}' does not exist. Skipping.\"
            else
                mkdir -p \"${DST}\"
                COUNT=0
                for FILE in \"${SRC}\"/${PAT}; do
                    [ -f \"\\\$FILE\" ] || { echo \"WARNING: No files matching '${PAT}' in ${SRC}. Skipping.\"; break; }
                    FNAME=\\\$(basename \"\\\$FILE\")
                    DEST=\"${DST}/\\\${SIM_JOB_ID}.\\\${TIMESTAMP}.\\\${FNAME}\"
                    cp \"\\\$FILE\" \"\\\$DEST\"
                    echo \"  Copied: \\\$FNAME  ->  \\\$(basename \\\"\\\$DEST\\\")\"
                    COUNT=\\\$(( COUNT + 1 ))
                done
                echo \"  Done: \\\$COUNT file(s) copied to ${DST}\"
            fi"
        done

        BACKUP_JOB_ID=$(sbatch \
            --dependency=afterok:$SIM_JOB_ID \
            --job-name="backup_${RUN_LABEL}" \
            --partition=${BACKUP_PARTITION} \
            --ntasks=1 \
            --cpus-per-task=1 \
            --time=00:10:00 \
            --output="${WORK_DIR}/backup_${RUN_LABEL}_%j.log" \
            --wrap="bash -c '
                set -euo pipefail

                SIM_JOB_ID=\"${SIM_JOB_ID}\"
                TIMESTAMP=\$(date +%Y%m%d_%H%M%S)

                echo \"========================================\"
                echo \" Backup for sim job: \$SIM_JOB_ID\"
                echo \" Timestamp        : \$TIMESTAMP\"
                echo \" Run label        : ${RUN_LABEL}\"
                echo \" Backup pairs     : ${NUM_BACKUP_PAIRS}\"
                echo \"========================================\"

                ${BACKUP_PAIRS_CODE}

                echo \"\"
                echo \"========================================\"
                echo \" All backups complete.\"
                echo \"========================================\"
            '" | awk '{print $4}')

        if [ -z "$BACKUP_JOB_ID" ]; then
            echo ""
            echo "ERROR: Backup job submission failed after run $RUN_NUMBER. Stopping."
            exit 1
        fi

        echo "  Run $RUN_NUMBER → Back Job ID: $BACKUP_JOB_ID  |  Backs up after Job $SIM_JOB_ID  |  Partition: $BACKUP_PARTITION"

        # Next sim job depends on backup finishing, not just the sim.
        # This guarantees backups are always complete before new
        # output files are written by the next run.
        PREV_JOB_ID=$BACKUP_JOB_ID

    else
        # Backup disabled: next sim waits only on the current sim
        PREV_JOB_ID=$SIM_JOB_ID
    fi

done

echo ""
echo "======================================"
if [ "$BACKUP_ENABLED" = "yes" ]; then
    echo "  All $RUN_NUMBER sim + $RUN_NUMBER backup jobs submitted!"
    echo "  Total jobs in chain: $(( RUN_NUMBER * 2 ))"
else
    echo "  All $RUN_NUMBER simulation jobs submitted!"
    echo "  Total jobs in chain: $RUN_NUMBER"
fi
echo "  Monitor:    squeue -u $USER"
echo "  Cancel all: scancel --user=$USER"
echo "======================================"
echo ""
