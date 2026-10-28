# Batch manifests for ready Sherlock packs (W46.sherlock-batch)

A `(cluster: sherlock)` item that ends its Mac-side preparation with `plan-edit.sh hold TAG 'ready to submit: …'`
also commits `packs/<TAG>.json` here. The batch (`../batch_mac.py`, `../batch.py`) takes only packs with a
manifest; `cluster-reach.py`'s batch request lists a ready pack without one as left out. Fields:

| field | meaning |
|---|---|
| `tag`, `pack` | the item, and the pack folder's name: `$AGENT_STATE/<mac>` on the Mac, `$GROUP_HOME/$USER/archive-suite/<pack>/` on Sherlock |
| `mac` | the prepared folder on the Mac, relative to `$AGENT_STATE` (results come back into it) |
| `submit` | the pack's own submit script, relative to the pack; run as `bash <pack>/<submit> <pack>`, unchanged |
| `jobs`, `gpu_hours` | the job count and the GPU-hour ceiling from the item's size-and-necessity review |
| `review` | where that review is; the owner's session reads it before `submit` |
| `imports` | what the CPU import job imports in the vLLM image before any GPU job is released: groups of `{"dir": <relative to the pack, put first on sys.path>, "modules": [...]}`; a group without `dir` imports from the image alone (e.g. `vllm`) |
| `creates` | path prefixes the pack's own jobs make (scratch root, results folder); the path check skips them |
| `provenance` | files, relative to the pack, whose paths are records of the Mac preparation and are never opened on Sherlock (an inventory of corpus sources) |
| `requires` | optional extra paths that must exist on Sherlock (a model snapshot, an overlay venv) |
| `results` | where the GPU jobs copy their outputs; the collect job adds `scratch/` (the `collect` paths) and `sacct.tsv` |
| `collect` | job evidence left in scratch: the pack's `jobs.tsv` and Slurm logs |
| `release` | the note `plan-edit.sh release` records when the results are home |

Paths may use `$HOME`, `$USER`, `$GROUP_HOME`, `$SCRATCH` and the sh.env variables (`$FS_ROOT`, `$HF_HOME`,
`$SH_IMG`, `$SH_SHIM`, …); the check resolves no others. The whole procedure is in
`execution-plans/sherlock-access.md` §"Batches".
