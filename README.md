# HPC Job Chaining with Slurm

A simple, reusable setup for automating sequential simulation runs on HPC clusters that use **Slurm** as the workload manager (e.g. clusters at IITs, IISc, or any university HPC facility).

Instead of manually waiting for a job to finish and then submitting the next one, this setup lets you queue an entire chain of runs with a single command. Each run starts automatically only after the previous one finishes successfully. After each run, a lightweight backup job automatically saves your output files before the next run begins.

---

## The Problem This Solves

In simulation-heavy research (CFD, MD, climate modelling, etc.), it is common to run a sequence of jobs where:
- Each run uses the output or restart files from the previous one, **or**
- You want to sweep through different input parameters (e.g. CFL numbers, iteration counts, mesh refinements) back to back

Doing this manually means you have to stay online, wait for the job to finish, back up your results, edit your input file, and resubmit. This setup automates all of that.

---

## Files

| File | Purpose |
|------|---------|
| `run.sh` | The main Slurm job script that runs your simulation |
| `submit_chain.sh` | Helper script that chains multiple runs with automatic dependencies and optional backups |

---

## How It Works

`submit_chain.sh` uses Slurm's `--dependency=afterok:<jobid>` flag. This tells the scheduler:

> "Don't start Job 2 until Job 1 has finished with exit code 0 (no errors)."

When backup is enabled, the chain looks like this for each run:

```
sim_job_1 → backup_job_1 → sim_job_2 → backup_job_2 → ...
```

The next simulation waits for the backup to finish, not just the sim. This guarantees your output files are fully saved before the next run overwrites them.

If any job in the chain fails, all downstream jobs are **automatically cancelled** by Slurm, saving your allocation credits.

---

## Requirements

- A cluster running **Slurm**
- Your compiled executable and all input files in the working directory
- Bash (available on all Linux HPC systems)

---

## Configuration

Before using `submit_chain.sh`, open it and edit the configuration block at the top:

```bash
# Name of your Slurm job script
JOB_SCRIPT="run.sh"

# Environment variable your job script reads to find the input file
INPUT_FILE_VAR="FLOW_IN_STAGE"

# Slurm partition for the backup job (use a CPU partition, not GPU)
BACKUP_PARTITION="standard"

# Set to "yes" to run backup jobs, "no" to only chain simulations
BACKUP_ENABLED="yes"
```

### Finding the right backup partition

Run this on the login node to see all available partitions:

```bash
sinfo -o "%P %a %l %D %t"
```

Use a CPU partition for the backup job. The backup is pure file copying — there is no reason to consume expensive GPU allocation for it. On clusters where GPU nodes are billed at a much higher rate than CPU nodes (which is typical), using the wrong partition here wastes credits.

### Configuring what gets backed up

Further down in `submit_chain.sh` you will find the backup pairs block:

```bash
NUM_BACKUP_PAIRS=2

BACKUP_SRC_1="restart_files"
BACKUP_DST_1="back_restart"
BACKUP_PAT_1="restart*.in"

BACKUP_SRC_2="tecplot_files"
BACKUP_DST_2="back_tecplot"
BACKUP_PAT_2="*.dat"
```

Each pair defines a source directory, a destination directory, and a glob pattern selecting which files to copy. To add more output directories, increment `NUM_BACKUP_PAIRS` and add the corresponding variables. To remove a pair, decrement `NUM_BACKUP_PAIRS` and delete the variables.

Backed-up files are named with the simulation job ID and a timestamp:

```
back_restart/361215.20250330_143022.restart0000.in
back_restart/361215.20250330_143022.restart0001.in
...
```

Originals are never touched — the backup always uses `cp`, never `mv`.

---

## Adapting `run.sh` to Your Cluster

Open `run.sh` and update the `#SBATCH` header and module loading section to match your cluster:

```bash
#SBATCH --partition=gpu          # change to your partition name
#SBATCH --gres=gpu:2             # adjust GPU count as needed
#SBATCH --time=48:00:00          # adjust wall time as needed

module purge
module load your_compiler_module  # replace with your cluster's module
```

Your job script must also read the input file from the environment variable named in `INPUT_FILE_VAR`. For example, if `INPUT_FILE_VAR="FLOW_IN_STAGE"`, your `run.sh` should contain something like:

```bash
if [ -n "$FLOW_IN_STAGE" ]; then
    cp "$FLOW_IN_STAGE" flow.in
fi
```

---

## Usage

### Case 1 — Single Run

If you just have one job to submit:

```bash
sbatch run.sh
```

### Case 2 — Chained Runs (different input parameters)

**Step 1** — Make one copy of your input file per run and edit the parameters you want to change in each:

```bash
cp flow.in flow_run1.in    # edit CFL / niter for run 1
cp flow.in flow_run2.in    # edit CFL / niter for run 2
cp flow.in flow_run3.in    # edit CFL / niter for run 3
```

**Step 2** — Make the scripts executable (only needs to be done once):

```bash
chmod +x run.sh submit_chain.sh
```

**Step 3** — Submit the entire chain with one command:

```bash
bash submit_chain.sh flow_run1.in flow_run2.in flow_run3.in
```

You will see output like:

```
======================================
  Submitting job chain
  Working dir  : /scratch/user/simulation
  Job script   : run.sh
  Backup       : yes
  Backup part  : standard
  Total runs   : 3
======================================

  Run 1 → Sim  Job ID: 12345  |  Input: flow_run1.in  |  Starts: immediately
  Run 1 → Back Job ID: 12346  |  Backs up after Job 12345  |  Partition: standard
  Run 2 → Sim  Job ID: 12347  |  Input: flow_run2.in  |  Waiting on: Job 12346
  Run 2 → Back Job ID: 12348  |  Backs up after Job 12347  |  Partition: standard
  Run 3 → Sim  Job ID: 12349  |  Input: flow_run3.in  |  Waiting on: Job 12348
  Run 3 → Back Job ID: 12350  |  Backs up after Job 12349  |  Partition: standard

======================================
  All 3 sim + 3 backup jobs submitted!
  Total jobs in chain: 6
  Monitor:    squeue -u $USER
  Cancel all: scancel --user=$USER
======================================
```

Done. The cluster handles the rest automatically.

---

## Important Notes

**Do not run `run.sh` directly when chaining.** `submit_chain.sh` calls `sbatch run.sh` for you automatically.

**Always run `submit_chain.sh` with `bash`, not `sbatch`:**

```bash
# Correct
bash submit_chain.sh flow_run1.in flow_run2.in

# Wrong — this would send the helper script itself to the queue
sbatch submit_chain.sh flow_run1.in flow_run2.in
```

`submit_chain.sh` is not a simulation. It just files the paperwork. It runs on the login node and finishes in under a second.

**Test your filesystem before your first chain run.** The backup job runs on a different partition than the simulation. Make sure your working directory (especially `/scratch`) is mounted and accessible on the backup partition's nodes:

```bash
sbatch --partition=standard --ntasks=1 --time=00:01:00 --wrap="ls /your/working/directory/"
```

If this returns your files, the backup partition can see your data. If it fails, change `BACKUP_PARTITION` to the same partition as your simulation jobs.

---

## Useful Slurm Commands

```bash
# Check your jobs in the queue
squeue -u $USER

# Cancel all your queued jobs
scancel --user=$USER

# Cancel a specific job
scancel <JOBID>

# View the output log of a simulation job
cat job.<JOBID>.out

# View the output log of a backup job
cat backup_<runlabel>_<JOBID>.log

# Check why a job is pending
squeue -u $USER -o "%.18i %.9P %.8j %.8u %.2t %.10M %.10l %.6D %R"

# See all available partitions and their status
sinfo -o "%P %a %l %D %t %N"
```

---

## Dependency Types (for reference)

If you need more control, Slurm supports several dependency conditions:

| Flag | Behaviour |
|------|-----------|
| `afterok:<jobid>` | Start only if the previous job succeeded (exit code 0) |
| `afterany:<jobid>` | Start as soon as the previous job ends, regardless of outcome |
| `afternotok:<jobid>` | Start only if the previous job failed |
| `singleton` | Start only when no other job with the same name is running |

---

## License

MIT — free to use, modify, and distribute.
