#!/bin/bash
# ============================================================
#  run.sh — Generic Slurm job script for MPI+GPU simulations
#
#  Works standalone (sbatch run.sh) or as part of an automated
#  chain via submit_chain.sh.
#
#  THINGS TO CHANGE FOR YOUR CLUSTER/PROJECT:
#  ------------------------------------------
#  1. #SBATCH headers         — partition name, GPU count,
#                               node count, wall time, etc.
#  2. INPUT_FILE_NAME         — name of your input file
#                               (must match what submit_chain.sh
#                               passes via INPUT_FILE_STAGE)
#  3. Environment setup       — replace the module/spack lines
#                               with whatever your cluster uses
#  4. The mpirun line         — replace ./a.out with your
#                               executable name
# ============================================================

# ── Slurm job settings ──────────────────────────────────────
# Adjust these to match your cluster and requirements
#SBATCH -N 1                        # number of nodes
#SBATCH --partition=gpu             # partition/queue name
#SBATCH --gres=gpu:2                # number of GPUs per node
#SBATCH --ntasks-per-node=2         # MPI ranks per node
#SBATCH --cpus-per-task=8           # CPU threads per MPI rank
#SBATCH --exclusive                 # exclusive node access
#SBATCH --time=24:00:00             # wall time limit (HH:MM:SS)
#SBATCH --job-name=my_simulation    # job name shown in squeue
#SBATCH --output=job.%J.out         # stdout log (%J = job ID)
#SBATCH --error=job.%J.err          # stderr log

# ── Go to the directory where sbatch was called from ───────
cd $SLURM_SUBMIT_DIR

# ── Capture start time (used for elapsed time at the end) ──
START_TIME=$(date +%s)

# ── Input file swap (required for submit_chain.sh to work) ─
# submit_chain.sh passes the correct input file for this run
# via the INPUT_FILE_STAGE environment variable.
# This block copies it in as your input file before the
# simulation starts, so each chained run uses different settings.
#
# Change "input.in" to whatever your input file is named.
INPUT_FILE_NAME="input.in"

if [ -n "$INPUT_FILE_STAGE" ] && [ -f "$INPUT_FILE_STAGE" ]; then
    echo "Using input file: $INPUT_FILE_STAGE"
    cp "$INPUT_FILE_STAGE" "$INPUT_FILE_NAME"
fi

# ── Load your environment ───────────────────────────────────
# Replace these lines with whatever your cluster uses.
# Common alternatives:
#   module load gcc openmpi cuda
#   source /path/to/your/env/setup.sh
#   conda activate myenv
module load gcc
module load openmpi
module load cuda

# ── MPI settings (tune for your cluster's interconnect) ────
export I_MPI_FABRICS=shm:ofi         # shm:dapl / shm:ofi / etc.
export I_MPI_DEBUG=0
export I_MPI_PIN=1
export I_MPI_PIN_DOMAIN=socket

# ── GPU settings ────────────────────────────────────────────
# Bind each MPI rank to the GPU matching its local rank ID
export CUDA_VISIBLE_DEVICES=$SLURM_LOCALID
export CUDA_DEVICE_MAX_CONNECTIONS=1  # prevent oversubscription

# ── MPI collective tuning (optional, remove if not needed) ─
export I_MPI_ADJUST_ALLTOALL=3
export I_MPI_ADJUST_BCAST=3
export I_MPI_ADJUST_REDUCE=3

# ── Print job info at start ─────────────────────────────────
echo "======================================"
echo "Job started at : $(date '+%Y-%m-%d %H:%M:%S')"
echo "Job ID         : $SLURM_JOB_ID"
echo "Node           : $SLURM_NODELIST"
echo "MPI ranks      : $SLURM_NTASKS"
echo "GPUs           : $SLURM_GPUS_ON_NODE"
echo "======================================"

# ── Run the simulation ──────────────────────────────────────
# Replace ./a.out with your executable name
time mpirun -np $SLURM_NTASKS ./a.out

# ── Calculate and print total elapsed time ─────────────────
END_TIME=$(date +%s)
ELAPSED_TIME=$(( END_TIME - START_TIME ))

echo "======================================"
echo "Job ended at   : $(date '+%Y-%m-%d %H:%M:%S')"
echo "Total run time : $(printf '%02d:%02d:%02d' $((ELAPSED_TIME/3600)) $((ELAPSED_TIME%3600/60)) $((ELAPSED_TIME%60)))"
echo "======================================"
