"""Read-only platform probes: what to record about a host while a suite runs. Each takes (sh, target) where sh(cmd)
runs a shell command on the host, and returns a small dict. Add a platform by adding a function to PROBES."""


def _first(sh, cmds):
    for c in cmds:
        out = sh(c + " 2>/dev/null").strip()
        if out:
            return out
    return ""


def nvidia(sh, target):
    """NVIDIA GPUs (RTX 6000, other workstation/server cards, DGX): clocks, temperature, memory, utilisation per GPU."""
    gpu = _first(sh, ["nvidia-smi --query-gpu=index,name,clocks.sm,temperature.gpu,memory.used,memory.total,utilization.gpu --format=csv,noheader"])
    return {"gpus": [l.strip() for l in gpu.splitlines()], "load": _first(sh, ["uptime | sed 's/.*load/load/'"])}


def dgx_spark(sh, target):
    """A DGX Spark (GB10, unified memory): nvidia-smi plus the served container's threads and memory if there is one."""
    d = nvidia(sh, target)
    c = (target.get("fault") or {}).get("container") or target.get("container")
    if c:
        d["container"] = _first(sh, [f"docker stats --no-stream --format '{{{{.PIDs}}}} pids {{{{.MemUsage}}}}' {c}"])
    d["mem_available_mb"] = _first(sh, ["awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo"])
    return d


def apple(sh, target):
    """Apple Silicon (MLX, llama.cpp, Ollama): memory pressure, CPU load, thermal state; no sudo needed."""
    return {"physmem": _first(sh, ["top -l 1 -n 0 | grep PhysMem"]), "cpu": _first(sh, ["top -l 1 -n 0 | grep 'CPU usage'"]),
            "thermal": _first(sh, ["pmset -g therm | tail -n +2 | tr '\\n' ' '"]), "pageouts": _first(sh, ["vm_stat | grep 'Pageouts'"])}


def generic(sh, target):
    """Anything else: load and free memory where available."""
    return {"load": _first(sh, ["uptime | sed 's/.*load/load/'"]), "mem": _first(sh, ["free -m | awk '/Mem:/{print $7\" MB available\"}'", "vm_stat | head -2 | tail -1"])}


PROBES = {"dgx-spark": dgx_spark, "linux-gpu": nvidia, "rtx": nvidia, "apple": apple, "generic": generic}
