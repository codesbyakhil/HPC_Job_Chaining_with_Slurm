# HPC_Job_Chaining_with_Slurm
A lightweight Slurm job-chaining setup for HPC clusters that automates sequential simulation runs. Submit multiple jobs at once with automatic `afterok` dependencies, ensuring each run starts only after the previous one succeeds—saving time, effort, and allocation credits.

# HPC Job Chaining with Slurm

A simple, reusable setup for automating sequential simulation runs on HPC clusters that use **Slurm** as the workload manager (e.g. clusters at IITs, IISc, or any university HPC facility).

Instead of manually waiting for a job to finish and then submitting the next one, this setup lets you queue an entire chain of runs with a single command. Each run starts automatically only after the previous one finishes successfully.

---

## The Problem This Solves

In simulation-heavy research (CFD, MD, climate modelling, etc.), it is common to run a sequence of jobs where:
- Each run uses the output or restart files from the previous one, **or**
- You want to sweep through different input parameters (e.g. CFL numbers, iteration counts, mesh refinements) back to back

Doing this manually means you have to stay online, wait for the job to finish, edit your input file, and resubmit. This setup automates all of that.

---

## Files

| File | Purpose |
|------|---------|
| `run.sh` | The main Slurm job script that runs your simulation |
| `submit_chain.sh` | Helper script that chains multiple runs with automatic dependencies |

---

## How It Works

`submit_chain.sh` uses Slurm's `--dependency=afterok:<jobid>` flag under the hood. This tells the scheduler:

> "Don't start Job 2 until Job 1 has finished with exit code 0 (no errors)."

If any job in the chain fails, all downstream jobs are **automatically cancelled**, saving your allocation credits.

---

## Requirements

- A cluster running **Slurm**
- Your compiled executable and all input files in the working directory
- Bash (available on all Linux HPC systems)

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
cp input.in input_run1.in
cp input.in input_run2.in
cp input.in input_run3.in
```

**Step 2** — Make the scripts executable (only needs to be done once):

```bash
chmod +x run.sh submit_chain.sh
```

**Step 3** — Submit the entire chain with one command:

```bash
bash submit_chain.sh input_run1.in input_run2.in input_run3.in
```

You will see output like:

```
======================================
  Submitting job chain
  Working dir: /home/user/simulation
  Number of runs: 3
======================================

  Run 1 → Job ID: 12345  |  input: input_run1.in  |  Starts: immediately
  Run 2 → Job ID: 12346  |  input: input_run2.in  |  Waiting on: Job 12345
  Run 3 → Job ID: 12347  |  input: input_run3.in  |  Waiting on: Job 12346

======================================
  All 3 jobs submitted successfully!
======================================
```

Done. The cluster handles the rest automatically.

---

## Important Notes

**Do not run `run.sh` directly when chaining.** `submit_chain.sh` calls `sbatch run.sh` for you automatically.

**Always run `submit_chain.sh` with `bash`, not `sbatch`:**

```bash
# Correct
bash submit_chain.sh input_run1.in input_run2.in

# Wrong — this would send the helper script itself to the queue
sbatch submit_chain.sh input_run1.in input_run2.in
```

`submit_chain.sh` is not a simulation. It just files the paperwork. It runs on the login node and finishes in under a second.

---

## Adapting `run.sh` to Your Cluster

Open `run.sh` and update the `#SBATCH` header and the environment/module loading section to match your cluster's setup:

```bash
#SBATCH --partition=gpu          # change to your cluster's partition name
#SBATCH --gres=gpu:2             # adjust GPU count as needed
#SBATCH --time=48:00:00          # adjust wall time as needed

# Replace the spack/module lines with whatever your cluster uses:
module load gcc
module load openmpi
# or
source /path/to/your/env/setup.sh
```

Everything else (the timing logic, the flow.in swap, the dependency chaining) works as-is.

---

## Useful Slurm Commands

```bash
# Check your jobs in the queue
squeue -u $USER

# Cancel all your queued jobs
scancel --user=$USER

# Cancel a specific job
scancel <JOBID>

# View the output log of a job
cat job.<JOBID>.out

# Check why a job is pending
squeue -u $USER -o "%.18i %.9P %.8j %.8u %.2t %.10M %.10l %.6D %R"
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
