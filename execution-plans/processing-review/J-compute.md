# J. Compute, API and hardware inventory

Date read for every source below: 2026-10-20. Pages were fetched through a summarising fetch tool, so a figure is the summary's reading of the page, not a copy of it. Where a page did not state something, the table says "not stated" and does not fill the gap from memory. Items marked [secondary] come from a third-party page or a search snippet and are weaker than the vendor pages.

## 1. Stanford Sherlock

### 1.1 Cluster size and GPU hardware

Sources: https://www.sherlock.stanford.edu/docs/tech/facts/ and https://www.sherlock.stanford.edu/docs/tech/ (both read 2026-10-20). The Facts page is dated "as of October 2026".

| Item | Figure |
|---|---|
| Compute nodes | 2,007 |
| CPU cores | 75,972 |
| GPUs, whole cluster (including owner nodes) | 1,256 across 14 models |
| User accounts / PI groups / owner groups | 9,180 / 1,352 / 228 |
| $SCRATCH filesystem | 14.6 PB Lustre, over 600 GB/s |
| $OAK | 93.9 PB |

The public `gpu` partition (49 nodes, 1,508 cores) is the part a general user can reach. The tech page lists these GPU nodes and says 200 GPUs in total across them.

| Nodes | GPUs per node | GPU model | Node RAM | Total GPUs |
|---|---|---|---|---|
| 1 | 4 | Tesla P100 PCIe | 256 GB | 4 |
| 2 + 1 | 4 | Tesla V100 SXM2 | 256 GB / 191 GB | 12 |
| 2 | 4 | Tesla V100 PCIe | 191 GB | 8 |
| 2 | 4 | Tesla V100S PCIe | 256 GB | 8 |
| 6 + 2 | 4 | GeForce TITAN Xp | 512 GB / 1 TB | 32 |
| 18 | 4 | GeForce RTX 2080 Ti | 256 GB | 72 |
| 4 | 4 | GeForce RTX 3090 | 256 GB | 16 |
| 8 | 4 | Tesla L40S | 256 GB | 32 |
| 2 | 4 | Tesla H100 SXM5 | 1 TB | 8 |
| 1 | 8 | Tesla H100 SXM5 | 2 TB | 8 |

So the public pool holds 16 H100, 32 L40S, 16 RTX 3090, 72 RTX 2080 Ti and the older cards. No A100 appears in the public table. The node-features page (https://www.sherlock.stanford.edu/docs/advanced-topics/node-features/) shows `GPU_SKU:A100_SXM4` only as an example constraint and lists P100, P40, RTX 2080 Ti and three V100 variants in the `gpu` partition output, so its list is older than the tech page. The `owners` partition (1,665 nodes) holds the rest of the 1,256 GPUs and is reserved for owner groups, who are the only users who can run there without preemption. Memory per card is not tabulated by the docs. The GPU page gives 16 GB for P100 and V100 examples, 24 GB for P40 and a `GPU_MEM` feature with values 16GB, 24GB, 32GB and 80GB. L40S memory is not stated on any page I read.

The `dev` partition holds 32 A30 cards cut into MIG 1g.6gb slices (6 GB each), for `sh_dev -g 1`.

### 1.2 Partitions and per-job limits

Source: https://www.sherlock.stanford.edu/docs/user-guide/running-jobs/ (the figures come from an illustrative `sh_part` snapshot on the page, not live data).

| Partition | Default / max runtime | Memory per core default / max | Per-user limits stated | Notes |
|---|---|---|---|---|
| normal (default) | 2 h / 2 days; 7 days with the `long` QOS | 6 / 8 GB | none stated | 20 to 64 cores per node, 128 to 384 GB RAM |
| bigmem | 2 h / 1 day | 6 / 64 GB | none stated | up to 4 TB RAM per node |
| gpu | 1 h / 2 days | 8 / 32 GB | 16 GPUs per user | 4 or 8 GPUs per node |
| dev | 1 h / 2 h | 6 / 8 GB | 4 cores and 2 GPUs per user (a footnote says 2 cores and 8 GB) | MIG slices only; the page conflicts with itself |
| service | 1 h / 2 h (table also says 2 days) | 1 / 8 GB | 2 jobs, 16 cores per user | the page conflicts with itself |
| owners | up to 7 days | n/a | n/a | pooled owner nodes; jobs preempted when the owner needs the node |

Job-count limits exist (`MaxSubmitJobsPerUser`, `MaxSubmitJobsPerAccount`, per https://www.sherlock.stanford.edu/docs/advanced-topics/job-management/) but the numbers are not published; users run `sh_part`. The GPU page (https://www.sherlock.stanford.edu/docs/user-guide/gpu/) gives no maximum GPUs per job or wall time. Jobs that do not request a GPU are rejected from the `gpu` partition. GPUs are requested with `-G` or `--gpus`, filtered with `-C` (for example `-C GPU_MEM:32GB` or `-C GPU_SKU:...`), and the default compute mode is exclusive.

### 1.3 Fair-share and queue norms

Sources: https://www.sherlock.stanford.edu/docs/advanced-topics/scheduling/ and the running-jobs page above.

Priority depends on job age, requested resources, partition and a fair-share score. The more CPU and GPU hours a user has used recently, the lower the priority of the next jobs, and the effect decays. There is no fixed upper bound on queue wait. Short, small jobs often start within minutes by backfill. Large multi-node jobs wait longer. Over-estimating the time limit hurts backfill. The docs call GPUs scarce and high-demand. `sh_dev` runs on dedicated nodes and normally starts without waiting.

### 1.4 Storage

Sources: https://www.sherlock.stanford.edu/docs/storage/ and https://www.sherlock.stanford.edu/docs/storage/filesystems/.

| Filesystem | Quota | Purge | Snapshots / backup |
|---|---|---|---|
| $HOME | 15 GB | not purged | snapshots; off-site replication |
| $GROUP_HOME | 1 TB per group | not purged | snapshots; off-site replication |
| $SCRATCH | 100 TB and 20 million inodes | files not modified for 90 days are purged; only changing contents resets the clock | none |
| $GROUP_SCRATCH | 100 TB and 20 million inodes | same 90-day rule | none |
| $L_SCRATCH | about 150 GB physical, no quota | purged when the job ends | none |
| $OAK | as purchased, in 10 TB increments | not purged | none by design; paid cloud backup optional |

Fail-safe caps across all /scratch directories are 125 TB and 25 million inodes per user, 250 TB and 50 million per group. `$COMMON_DATASETS` is a read-only shared area that holds pre-downloaded Ollama models, among other things (https://www.sherlock.stanford.edu/docs/storage/common-datasets/).

### 1.5 Software, containers, internet, LLM serving

| Question | Finding | Source |
|---|---|---|
| Apptainer | works on any login or compute node with no module; `apptainer pull docker://...` from Docker Hub or NGC; store images in $GROUP_HOME; run GPU jobs with `--nv`; images that start an SSH server are forbidden; the page says NGC containers are supported only on Pascal and Volta, a statement that predates the L40S and H100 nodes | https://www.sherlock.stanford.edu/docs/software/containers/apptainer/ |
| Enroot | a second container tool is listed in the navigation; I did not read its page | https://www.sherlock.stanford.edu/docs/ |
| Outbound internet from compute nodes | not stated on any page I read (concepts, scheduling, troubleshooting, Python, containers, Ollama, coding agents, submission options) | those pages |
| Hugging Face download | not documented. The Python page (pip, venv, uv) does not mention HF_HOME. An inference is that a model can be fetched on a login or transfer node into $SCRATCH or $GROUP_HOME and loaded from that path, but no page confirms this | https://www.sherlock.stanford.edu/docs/software/using/python/ |
| vLLM | not documented anywhere I read. The only documented LLM server is Ollama (module `ml ollama`, batch script requests one GPU with 16 to 80 GB GPU memory for 2 hours, picks a random port, writes the endpoint to ~/.ollama_server, SSH tunnel for clients) | https://www.sherlock.stanford.edu/docs/software/using/ollama/ |
| Python environments | `pip install --user`, venv, uv (`ml uv`); build on a compute node; keep environments in $GROUP_HOME | https://www.sherlock.stanford.edu/docs/software/using/python/ |
| Interactive | `sh_dev` (defaults 1 core, 4 GB, 1 h; `-g` for GPU slice, `-p gpu` for a real GPU); `salloc` default 1 core for 2 h; SSH to a node only while you hold a job there | https://www.sherlock.stanford.edu/docs/user-guide/running-jobs/ |
| OnDemand | https://ondemand.sherlock.stanford.edu; Jupyter, JupyterLab, MATLAB, RStudio, TensorBoard, code-server; the page shows no GPU option in the forms | https://www.sherlock.stanford.edu/docs/user-guide/ondemand/ |
| Data risk level | a search snippet from the SRCC page says Sherlock is approved for low and moderate risk data only [secondary; I did not fetch that page] | https://srcc.stanford.edu/sherlock-high-performance-computing-cluster |

Open questions for Sherlock support (srcc-support@stanford.edu): does a compute node reach huggingface.co, which GPUs inside `gpu` accept Apptainer images with a current CUDA, what is the per-job GPU cap, and is a vLLM server on a GPU node allowed as a long job (the `gpu` partition caps a job at 2 days).

### 1.6 Account process

Sources: https://www.sherlock.stanford.edu/docs/getting-started/ and https://www.sherlock.stanford.edu/docs/concepts/.

Sherlock is free. The group must be led by a Stanford faculty member (tenure line; for the School of Medicine, University Tenure Line). Students, postdocs, staff and visitors cannot request a group; the faculty sponsor emails srcc-support@stanford.edu with the names and SUNet IDs and explicitly consents. Access lasts while the SUNet ID is active or until the sponsor closes it. On closure $HOME is archived to $SCRATCH and deleted after 90 days. Sherlock is for research only, not coursework. Creation time is not stated.

## 2. Stanford FarmShare (fallback)

Sources: https://docs.farmshare.stanford.edu/, https://docs.farmshare.stanford.edu/slurm/, https://docs.farmshare.stanford.edu/policy/, https://docs.farmshare.stanford.edu/software/ (all 2026-10-20).

| Item | Finding |
|---|---|
| Purpose and eligibility | coursework and unsponsored research; any full-service SUNet ID; no high-risk data; not for sponsored research |
| Hardware | 26 compute nodes (iron, rye, wheat, oat classes), 4 login nodes, Ubuntu 24.04, Slurm 25.11.1 |
| GPUs | December 2025 expansion added 6 GPU nodes with 4 NVIDIA L40S each, 24 L40S in all; the older oat nodes' GPU models are not stated |
| Partitions | normal (default, max 188 GB, 256 CPU), bigmem (768 GB, 344 CPU), interactive (188 GB, 16 CPU) |
| Per-user QOS limits | normal: 1024 submitted, 128 running, 256 CPU and 3 GPUs; gpu QOS: 32 submitted, 4 running, 1 to 6 GPUs per job; dev: 1 job, 8 CPU, 1 GPU, 32 GB, 8 h; long: 4 jobs, 32 CPU, 7 days; bigmem: min 192 GB, max 768 GB; interactive: 1 job, up to one day |
| GPU request syntax | not documented on the Slurm page; the page shows GPU limits only inside the QOS table |
| Storage | TrueNAS all-NVMe for HOME and /scratch; quotas and purge days are not stated on any page I read; images suggested in /scratch/users/$USER |
| Software | Apptainer via `module load apptainer`; Python 3.13 module; cuda/11.4.4 module listed (old); internet access, Hugging Face and vLLM not covered |
| Fair-share | priority from wait time, job size and recent usage |

## 3. API prices (USD per million tokens, read 2026-10-20)

### 3.1 Gemini

Source: https://ai.google.dev/gemini-api/docs/pricing. Image rules: https://ai.google.dev/gemini-api/docs/media-resolution and https://ai.google.dev/gemini-api/docs/image-understanding.

| Model | Free tier | Standard in / out | Batch in / out |
|---|---|---|---|
| Gemini 4 Argon (`gemini-4-argon`) | no | 2.00 / 10.00 until 30 Nov 2026; 4.00 / 20.00 from 1 Dec 2026 | 1.00 / 5.00, doubling the same day |
| Gemini 3.8 Flash | yes | 0.75 / 3.75 until 31 Dec 2026; 1.50 / 7.50 from 1 Jan 2027 | 0.375 / 1.875, doubling the same day |
| Gemini 3.6 Flash | yes | same as 3.8 Flash, same dates | same |
| Gemini 3.5 Flash-Lite | yes | 0.30 / 2.50 | 0.15 / 1.25 |
| Gemini 3.1 Flash-Lite | yes | 0.25 / 1.50 (audio in 0.50) | 0.125 / 0.75 |
| Gemini 3 Flash Preview | yes | 0.50 / 3.00 | 0.25 / 1.50 |
| Gemini 3.1 Pro Preview | no | 2.00 / 12.00 up to 200k prompt; 4.00 / 18.00 above | 1.00 / 6.00; 2.00 / 9.00 |
| Gemini 2.5 Pro | yes | 1.25 / 10.00 up to 200k; 2.50 / 15.00 above | 0.625 / 5.00 |
| Gemini 2.5 Flash | yes | 0.30 / 2.50 | 0.15 / 1.25 |
| Gemini 2.5 Flash-Lite | yes | 0.10 / 0.40 | 0.05 / 0.20 |

The Batch API gives a 50 percent reduction. The newest Pro listed is 3.1 Pro Preview and the newest Flash-Lite is 3.5. Free-tier rate limits (requests per minute or day) are not on the page; Google points to AI Studio, so I have no figure (https://ai.google.dev/gemini-api/docs/rate-limits, which lists paid tiers only: Tier 1 needs billing linked, Tier 2 needs $100 spend, Tier 3 needs $1,000). The Gemini 4 and 3.8 price rises are a scheduling fact that matters for any budget that runs past November or January.

Image tokens: for Gemini 3 and 4 models `media_resolution` gives about 280 (low), 560 (medium), 1,120 (high and default) and 2,240 (ultra high, per item) tokens per image. The image-understanding page gives the older rule of 258 tokens per 768 px tile. Documents are billed at the image rate.

### 3.2 Anthropic

Source: https://platform.claude.com/docs/en/about-claude/pricing. Vision rules: https://platform.claude.com/docs/en/build-with-claude/vision.

| Model | Input | Output | Cache read |
|---|---|---|---|
| Claude Fable 5.1 (also Fable 5) | 10 | 50 | 0.25 (Fable 5: 1.00) |
| Claude Opus 5.5 | 4 | 20 | 0.20 |
| Claude Opus 5 / 4.8 / 4.7 / 4.6 / 4.5 | 5 | 25 | 0.50 |
| Claude Sonnet 5.5 | 2 | 10 | 0.10 |
| Claude Sonnet 5 | 2 (now permanent; the planned 3 / 15 rise was cancelled) | 10 | 0.20 |
| Claude Sonnet 4.6 / 4.5 | 3 | 15 | 0.30 |
| Claude Haiku 5.5, prompts up to 100k tokens | 0.10 | 0.50 | 0.01 |
| Claude Haiku 5.5, prompts over 100k tokens | 0.50 | 2.50 | 0.05 |
| Claude Haiku 4.5 | 1 | 5 | 0.10 |

The Mythos models are limited-availability. The Batch API takes 50 percent off input and output. New users get a small amount of free credit; no standing free tier. Claude 4.7 and later use a tokenizer that produces about 30 percent more tokens for the same text.

Image rule: an image costs ceil(width/28) times ceil(height/28) tokens. Claude 4.7 and later models allow a long edge of 2,576 px and up to 4,784 tokens per image; earlier models allow 1,568 px and 1,568 tokens. A 1000 by 1000 px image is 1,296 tokens. A 3840 by 2160 image is 4,784 tokens on the high-resolution tier. Limits are 100 images per request for 200k-context models, 600 otherwise, 10 MB per image, 8000 px maximum, and a stricter 2000 px edge when a request holds more than 20 images. The page's own example prices a 1000 by 1000 image at about $5.18 per thousand images on Opus 5.5.

### 3.3 OpenAI

Source: https://developers.openai.com/api/docs/pricing (openai.com/api/pricing returned 403).

| Model | Input | Cached input | Output | Batch in / out |
|---|---|---|---|---|
| gpt-6-astra | 10.00 | 1.00 | 50.00 | 5.00 / 25.00 |
| gpt-6.1-sol | 2.00 | 0.10 | 10.00 | 1.00 / 5.00 |
| gpt-6-sol | 2.00 | 0.20 | 10.00 | 1.00 / 5.00 |
| gpt-6-luna | 0.10 | 0.01 | 0.50 | 0.05 / 0.25 |
| gpt-5.6-sol | 4.00 | 0.40 | 20.00 | 2.00 / 10.00 |
| gpt-5.6-terra | 2.00 | 0.20 | 12.00 | 1.00 / 6.00 |
| gpt-5.6-luna | 0.20 | 0.02 | 1.20 | 0.10 / 0.60 |
| gpt-5.5 | 5.00 | 0.50 | 30.00 | 2.50 / 15.00 |
| gpt-5.4-mini | 0.75 | 0.075 | 4.50 | 0.375 / 2.25 |
| gpt-5.4-nano | 0.20 | 0.02 | 1.25 | 0.10 / 0.625 |
| gpt-5-mini | 0.25 | 0.025 | 2.00 | 0.125 / 1.00 |
| gpt-5-nano | 0.05 | 0.005 | 0.40 | 0.025 / 0.20 |
| gpt-4.1-mini | 0.40 | 0.10 | 1.60 | 0.20 / 0.80 |
| gpt-4o-mini | 0.15 | 0.075 | 0.60 | 0.075 / 0.30 |

Prices above are for prompts up to 272k tokens; longer prompts cost more (gpt-5.5 doubles). Batch and Flex are about half the standard rate. GPT-5.6 Sol has promotional pricing through at least 21 November 2026. The page does not state which of these models are the "mini" tier of the GPT-6 line (luna looks like the small one by price, but the page does not say so), and I found no OpenAI image-token rule in this fetch.

### 3.4 Mistral OCR

Sources: https://docs.mistral.ai/inference/pricing, https://docs.mistral.ai/models/ocr-3-25-12, and a search result summarising https://mistral.ai/news/ocr-4/ [secondary for the batch figure].

| Model | Price per 1,000 pages | Batch |
|---|---|---|
| OCR 4.1 (current; the latest alias points at it per search results) | 4.00; cached input 0.40 | 2.00 per the OCR 4 announcement as summarised by search; the pricing page fetch did not show a batch value |
| OCR 3 (`mistral-ocr-2512`, 18 Dec 2025) | 2.00; 3.00 per annotated page | not stated |

Mistral language models on the same page: Large 4 at 1.36 in / 4.18 out, Large 3 at 0.50 / 1.50, Medium 3.5 at 1.50 / 7.50, Small 4 at 0.15 / 0.60. The page lists no free API quota.

### 3.5 OpenRouter, open-weight vision models

Source: https://openrouter.ai/api/v1/models (fetched with curl, 468 models, filtered to models that accept image input), and https://openrouter.ai/api/v1/models/<id>/endpoints for providers. Prices are per million tokens. No per-image charge appears for any of these models (the image field is zero), so images are billed as input tokens. Provider quantisation is shown where listed.

| Model | In / out (headline) | Providers and their range |
|---|---|---|
| qwen/qwen3.5-9b | 0.08 / 0.13 | Darkbloom fp4 0.08 / 0.13; DeepInfra bf16 0.10 / 0.15; SiliconFlow fp8; Parasail bf16 0.10 / 0.25; Together 0.17 / 0.25 |
| qwen/qwen3.5-27b | 0.27 / 2.16 | not queried |
| qwen/qwen3.5-35b-a3b | 0.14 / 1.00 | not queried |
| qwen/qwen3.5-122b-a10b | 0.26 / 2.08 | not queried |
| qwen/qwen3.5-397b-a17b | 0.39 / 2.34 | not queried |
| qwen/qwen3.6-27b | 0.25 / 2.00 | Chutes fp8 0.25 / 2.00; Reka; SiliconFlow; DeepInfra 0.32 / 3.20; Phala; Venice; Alibaba 0.45 / 2.70 |
| qwen/qwen3.6-35b-a3b | 0.10 / 0.95 | Darkbloom fp4 0.05 / 0.70; AkashML, DeepInfra, Parasail fp8 0.10 / 0.90 to 0.95; Venice; Phala; SiliconFlow; CoreWeave and AtlasCloud 0.25 / 1.25 |
| qwen/qwen3.6-flash and 3.7-flash | 0.188 / 1.125 and 0.03 / 0.13 | hosted Qwen models; 1M context |
| qwen/qwen3.8-27b, 3.8-flash, 3.8-omni-flash | 0.04 / 1.35; 0.15 / 0.47; 0.15 / 0.47 | not queried |
| qwen/qwen3-vl-8b-instruct | 0.25 / 0.75 | Parasail bf16 only |
| qwen/qwen3-vl-30b-a3b-instruct | 0.15 / 0.60 | not queried |
| qwen/qwen3-vl-235b-a22b-instruct | 0.21 / 1.90 | not queried |
| google/gemma-4-31b-it | 0.20 / 0.40 (a free variant exists) | CoreWeave fp4 0.10 / 0.34 up to SiliconFlow fp8 0.75 / 1.00; 15 endpoints, many fp4 or fp8; Crusoe, Novita, Parasail bf16 or fp8 at 0.14 to 0.15 / 0.40 |
| google/gemma-4-26b-a4b-it | 0.076 / 0.255 (a free variant exists) | Darkbloom 0.042 / 0.22 up to Google 0.15 / 0.60; 13 endpoints |
| z-ai/glm-4.6v | 0.30 / 0.90 | Novita bf16 and Z.AI fp8, both 0.30 / 0.90 |
| z-ai/glm-4.5v | 0.60 / 1.80 | not queried |
| z-ai/glm-5v-turbo | 1.20 / 4.00 | not queried |
| meta-llama/llama-4-maverick | 0.188 / 0.652 | DigitalOcean 0.188 / 0.652; Parasail 0.35 / 1.00; Google 0.35 / 1.15 |
| meta-llama/llama-4-scout | 0.10 / 0.30 | not queried |
| nvidia/nemotron-3.5-super-vl | 0.15 / 0.50 (a free variant exists) | not queried |
| mistralai/mistral-small-2603 | 0.15 / 0.60 (batch 0.075 / 0.30) | not queried |
| moonshotai/kimi-k2.6 | 0.65 / 3.41 | not queried |

Not listed on OpenRouter as image-input models today: GLM-OCR, LightOnOCR and InternVL. A scan for names containing ocr, lighton, internvl, paddle or olmocr found only `dots-studio/dots-3-note-preview:free`. Qwen3-VL pricing above is for the Qwen3-VL generation; Qwen2.5-VL-72B is 0.80 / 1.00. OpenRouter also lists Gemini and a batch variant for several models (for example `google/gemini-3.5-flash-lite:batch` at 0.15 / 1.25), which matches Google's own batch halving. OpenRouter's own page shows 3.8 Flash at 0.825 / 4.125, which is a 10 percent markup over Google's 0.75 / 3.75 (my reading; the page does not say so).

Rough cost of one phone photo, as arithmetic and not a measurement. Assume one image of 1,120 tokens on Gemini (high resolution) and 1,500 output tokens for the transcription and metadata. Gemini 3.5 Flash-Lite is about $4.1 per 1,000 photos at standard rates and about $2.1 in batch. Gemini 3.6 Flash is about $6.5 per 1,000 until the 1 January 2027 rise, about $13 after, and half of each in batch. Claude Haiku 5.5 at 3,000 image tokens and the same output is about $1.1 per 1,000 photos (image token count depends on which resolution tier the model uses; the vision page says tier 2,576 px applies to 4.7 and later, and I assumed Haiku 5.5 is covered). Qwen3.6-35B-A3B at 1,500 image tokens through Parasail or DeepInfra is about $1.6 per 1,000. Mistral OCR 4.1 is $4 per 1,000 pages, $2 in batch if the announcement figure holds, and returns text only.

## 4. Subscriptions

| Plan | Price and published limit | Source |
|---|---|---|
| Claude Free | $0; everyday use, no multiplier stated | https://claude.com/pricing |
| Claude Pro | $20 a month, or $17 billed annually; at least 5x Free per five-hour session | same |
| Claude Max | from $100 a month, 5x or 20x Pro per five-hour session; includes $100 to $200 a month of API credits | same |
| Claude Team | Standard seat $25 monthly or $20 annual; Premium seat $125 or $100, 5x Standard | same |
| Claude Education | not listed; separate page | same |
| All Claude plans | rolling five-hour window; paid plans also have weekly limits whose size is not published | same |
| ChatGPT | the official pages (chatgpt.com/pricing, help.openai.com) returned 403. Search results [secondary] give Go $8, Plus $20 and Pro at $100, $200 and $500 a month; Pro tiers reportedly 5x, 10x and 25x Plus (press, not OpenAI); text chat described as unlimited on every plan with abuse safeguards and caps on images, uploads and Codex; the $200 tier reopened in late September with about half its earlier allowance | https://chatgpt.com/pricing/ (blocked); secondary summaries returned by search |

The user's own memory note says the Education plan gives about 5x usage in a weekly window; this fetch could not confirm that from a public page.

## 5. Mac configurations currently sold (US store)

Sources: https://www.apple.com/shop/buy-mac/macbook-air, /macbook-pro, /mac-mini, /mac-studio (prices read from the page data with curl; memory options from the fetched spec pages https://www.apple.com/macbook-air/specs/ and the configuration pages), and Daring Fireball, 25 August 2026, https://daringfireball.net/2026/08/configurations_and_pricing_for_new_mac_minis_and_mac_studios [secondary, for upgrade prices; its figures are August prices and the same article-linked search result says Mac mini prices changed three times this year]. All read 2026-10-20.

| Line | Chip | Memory choices | Price of the line's configurations (from Apple store page) |
|---|---|---|---|
| MacBook Air 13 | M5, 10-core CPU, 8- or 10-core GPU | 16 GB base, 24 GB, 32 GB | $1,299 (8-core GPU, 16/512), $1,399 (10-core GPU) |
| MacBook Air 15 | M5, 10/10 | 16 GB base, 24 GB, 32 GB | $1,499 |
| MacBook Pro 14 | M5, 10/10 | 16, 24, 32 GB | $1,999; $2,149 with nano-texture |
| MacBook Pro 14 | M5 Pro (15/16 or 18/20) | 24, 48 GB | $2,499 and $2,699; nano-texture $2,649 and $2,849 |
| MacBook Pro 14 | M5 Max (18/32 or 18/40) | 36, 48 GB | $4,099 and $4,699 |
| MacBook Pro 16 | M5 Pro (18/20) | 24, 48 GB | $2,999 |
| MacBook Pro 16 | M5 Max (18/32 or 18/40) | 36, 48 GB | $4,399 and $4,999 |
| Mac mini | M6, 12/12 | 16 GB base, 24 GB (+$200), 32 GB (+$400); SSD 256 GB, +$200 for 512 GB, +$500 for 1 TB | $899 |
| Mac mini | M5 Pro 15/16 and 18/20 | 24 GB base, 48 GB (+$600), 64 GB (+$1,000) | $1,699 and $1,899 |
| Mac Studio | M5 Max 18/32 | 36 GB | $2,499 |
| Mac Studio | M5 Max 18/40 | 48 GB base, 64 GB (+$400), 128 GB (+$2,000) | $3,099 |
| Mac Studio | M5 Ultra 30/64 | 96 GB base, 256 GB (+$4,000), 512 GB announced for late October | $5,499 |
| Mac Studio | M5 Ultra 36/80 | as above | $6,799 |

Memory-upgrade prices for the MacBook Air and MacBook Pro were not retrievable; Apple's configurator loads them client-side, and neither page text nor the fetched configuration pages carried them. Mac mini M5 Pro memory bandwidth is 307 GB/s and the M6 mini 170 GB/s per Apple's page (https://www.apple.com/mac-mini/). There is no 8 GB configuration in the MacBook Air list today, so the floor for a user buying new is 16 GB. Users with older Macs (8 GB M1 and M2 Airs) are not covered by a current-sales table and still exist in the field.

## 6. What this means for each user profile

Laptop (on-device models, no cloud). A new buyer starts at 16 GB unified memory on a $1,299 Air or the $899 Mac mini, and the 24 GB and 32 GB upgrades exist but cost real money, so the realistic installed base spreads over 8, 16 and 24 GB with 16 GB the modal new machine. With the operating system and the apps resident, a 16 GB machine leaves room for a model of a few billion parameters at 4-bit quantisation, which is the 4B to 9B class in the Qwen3.5 and Gemma 4 families. The 26B to 35B mixture-of-experts models need a 32 GB machine at the least, which means a $400 upgrade on the mini or a 32 GB Air. Photographs are the input, so any image-token cost is paid in memory and time rather than dollars. For this profile the design question is how small a vision model can read a box photograph at the working resolution, and what the app does on an 8 GB machine.

Cheap API. Per thousand photos the arithmetic above puts Claude Haiku 5.5 near $1, Qwen3.6-35B-A3B and Gemma 4 through OpenRouter near $1 to $2, Gemini 3.5 Flash-Lite near $4 and $2 in batch, and Mistral OCR 4.1 at $4 and $2 in batch for text only. These are within a few dollars of one another, so the choice rests on accuracy and on how stable the price is. Two prices are scheduled to move: Gemini 3.6 and 3.8 Flash double on 1 January 2027, and Gemini 4 Argon doubles on 1 December 2026. The open-weight models on OpenRouter list five to fifteen providers each with different quantisation, so a user who picks one is also picking whichever provider OpenRouter routes to unless the app pins a provider. Several Gemini models have a free tier, but its rate limits are not published on the pricing or rate-limit pages. A batch interface halves the cost and is suited to a box of hundreds of photographs processed overnight.

Premium API. Claude Sonnet 5.5 at $2 in and $10 out, GPT-6.1 Sol at $2 and $10, and Gemini 3.1 Pro at $2 and $12 (up to 200k prompt) sit at nearly the same price. Opus 5.5 is $4 and $20, Fable 5.1 and GPT-6 Astra are $10 and $50, and Gemini 4 Argon is $2 and $10 now but $4 and $20 from December. The Claude image rule makes a high-resolution photograph cost about 3,900 to 4,800 tokens, so the image side of a premium call is roughly three times the Gemini default of 1,120 tokens; the price per photograph is dominated by image tokens plus the length of the transcription. The Claude Max subscription includes $100 to $200 a month of API credits, which matters for a user who already pays for it.

Cluster. Sherlock offers 16 H100 and 32 L40S cards to any user, plus 72 RTX 2080 Ti and 16 RTX 3090, with a 16-GPU per-user limit, a 2-day job cap in the `gpu` partition and a 90-day scratch purge. Fair-share lowers priority after heavy use, and the docs call GPUs scarce, so a long vLLM run of a 30B-class model is a queue-and-wait workload, not an interactive one; `sh_dev -g` gives only a 6 GB MIG slice. Three things the design needs are undocumented and must be asked of support before it is built on: outbound access from compute nodes (so whether Hugging Face weights can be fetched in a job), whether vLLM and its container images run on the H100 and L40S nodes, and the per-job GPU cap. The workable plan the docs support is to download weights on a login or transfer node into $SCRATCH or $GROUP_HOME, run vLLM or Ollama in an Apptainer image on a GPU node, and tunnel to it. Access needs a faculty sponsor, which a person outside a lab cannot supply; Sherlock is closed to coursework and carries a low and moderate data-risk limit (secondary). FarmShare is the fallback for people without a sponsor: 24 L40S GPUs, one to six GPUs per job under the `gpu` QOS, no sponsored research, no high-risk data, quotas not published, GPU request syntax not on its Slurm page. Neither cluster is a service the Archive Suite can assume most users have, which matches the user's own note that most users have no FarmShare.
