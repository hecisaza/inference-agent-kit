# Platforms and backends

The suites only need an OpenAI-compatible API, so a target can be anything that serves one. What differs per setup is
how a server is started and stopped (the **backend**) and what is worth recording about the machine while a suite runs
(the **platform** probe). Both are declared in `lab.yaml`; `lab.examples/` has a file for each setup below.

| Setup | backend | platform | artifact | notes |
|---|---|---|---|---|
| DGX Spark recipe (one to four Sparks, ring or switch) | `recipe-docker` | `dgx-spark` | docker image, streamed to every Spark and compared by id | the recipe's `start.sh restart` starts every rank; build on a Spark that is not serving |
| RTX 6000 / other NVIDIA workstation or server (vLLM, SGLang, TensorFold cuda) | `service` or `command` | `rtx` (or `linux-gpu`) | none, or a path hashed by `plan` | per-GPU clocks, temperature, memory and utilisation from `nvidia-smi` |
| Apple Silicon (MLX, llama.cpp, Ollama) | `command` | `apple` | model folder or GGUF, hashed by `plan` | runs locally (`local: true`), no ssh; memory pressure and thermal state from `top`, `vm_stat`, `pmset` |
| Anything else with an OpenAI-compatible API | `command` or `service` | `generic` | optional | load and free memory |

## Backends

- **`recipe-docker`**: `recipe_dir`, `head`, `start` (run with `restart` appended), `env` (plus `IMAGE` from `image`),
  `api`, `model`; `build: {recipe_checkout, command}` on `build_host`. `ship` streams the image once from the build host to
  every other host and refuses when a host has less than `min_free_gb`.
- **`command`**: `host` (`local` or a `hosts:` entry; `local: true` runs commands on the agent's machine), `cwd`, `start`,
  `stop`, `env`, `api`, `model`. `start` must return: daemonise the server (nohup / setsid / tmux). Readiness is the API
  answering `/models`. `artifact` (a path) is hashed so the report names the weights.
- **`service`**: `host`, `service: {kind: systemd-user | systemd | launchd, name}`, optional `env_file` + `env` written before
  the restart (an `EnvironmentFile=` for systemd, or a file your launchd plist's program reads).

## Per-target options the suites read

- `chunk`: the engine's prompt chunk or prefill batch (TensorFold dsv41 2048; llama.cpp `-b`; vLLM `--max-num-batched-tokens`).
  The boundary suite cuts prompts at c-1, c, c+1 for the first three chunks and divides the prefix-cache prompts at and
  off chunk ends, so it tests the boundaries that matter on that engine.
- `fault: {container, trigger_path, exit_status, cases}`: the fault suite; `recipe-docker` only (it reads container exit codes).
- `bench_cmd`: an external benchmark (for example `grill-perf …`), run with `{api}`, `{model}`, `{label}`, `{out}` filled in.

## Adding a platform or backend

- A probe: add a function `(sh, target) -> dict` to `suites/probes.py` and register it in `PROBES`. Keep it read-only.
- A backend: add a class to `scripts/pairtest` with `start`, `artifact_id`, `build`, `ship`, and register it in `BACKENDS`.
- A suite: a function `(ctx) -> {"ok": bool, …}` in `suites/`, registered in that module's `SUITES`. `ctx` gives `api`,
  `model`, `opts`, `log`, `target`, `head`, `hosts`, `ssh`, `platform`, `restart`, `sample`.

What does not change across platforms: the rules in `AGENTS.md`, the evidence rules, the review step, the PR template.
