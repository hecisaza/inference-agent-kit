# Triage: issue {{ISSUE_URL}} — how can this lab work on it?

Read-only. You are in a checkout of `{{REPO}}`, the recipe this lab serves: `{{LIVE_MODEL}}` at `{{LIVE_API}}`
(an OpenAI-compatible API). Read the issue below, the repository's README (what it serves, on which hardware, its
patch table) and its `local.sh.example` or `config.sh` when present. Run nothing against the lab or the live build.
Write one file, `triage.json`, and change nothing else.

`triage.json` has exactly these keys:

- `kind`, one of:
  - `api`: the problem can be shown with requests to the served API against the live build as it runs (prompt shapes,
    tools, response formats, timings, idle gaps, long contexts). An agent will try to reproduce it there and fix it.
  - `lab`: showing it needs a configuration the live build does not run (another engine setting, another model, quant
    or rank count), a restart, a crash, a lockup, a hardware, driver, fabric or memory condition, or a load the live
    build must not take. A person schedules the lab for it.
  - `feature`: a feature request, an idea, a question, or a data point with no defect to reproduce.
  - `elsewhere`: a different recipe, topology or hardware than this repository serves; say which.
- `why`: one or two sentences, from the issue's own words.
- `repro`: for `api`, the request or sequence that should show it (shape, settings, what to look for); for `lab`, the
  configuration or condition needed (setting names and values from the issue, what must be restarted); else "".
- `patches`: the patch numbers or files of this repository the issue points at (a list, may be empty).
- `confidence`: `high`, `medium` or `low`.

Public text: no host names, addresses or users.

## The issue

{{ISSUE_MD}}
