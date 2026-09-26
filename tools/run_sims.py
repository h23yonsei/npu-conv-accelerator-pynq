#!/usr/bin/env python3
"""
Reproduce every verification result in this repository.

    python tools/run_sims.py                                  # everything
    python tools/run_sims.py --vivado C:/Xilinx/Vivado/2022.1
    python tools/run_sims.py --sim verilator                  # Verilator instead of Vivado
    python tools/run_sims.py --skip-hdl                       # Python checks only

Checks, in order:

1. Golden model equivalence  golden_model/test_conv2d.py: the tiled conv2d_9for matches the naive
                             conv2d_6for on all 5 cases.
2. Golden model network      golden_model/run_network.py on the first 20 test images: 19 of 20
                             predictions match label.npy and 19 of 20 match the argmax of the
                             float reference output.npy.
3. Test vectors              tools/gen_tb_vectors.py regenerates the testbench vectors,
                             tb_config.svh and tb_top_cases.svh in a scratch copy; the committed
                             files must be byte-identical to that output.
4. Conv engine               rtl/tb/tb_conv_engine.sv: every OFM word conv_engine writes for one
                             tile matches the golden model.
5. NPU top level             rtl/tb/tb_npu_top.sv: five tiles run through npu_top's AXI4-Lite
                             CSRs, with the block RAMs' port B modeled as the block design
                             configures it; every OFM word matches the golden model.

HDL checks use Vivado's simulator (xvlog/xelab/xsim) when Vivado is installed, and Verilator
otherwise or with --sim verilator. Output goes to build/sim/, which is git-ignored.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BUILD = REPO / "build" / "sim"


# ---------------------------------------------------------------------------
def find_vivado(explicit: str | None) -> Path | None:
    for cand in (explicit, os.environ.get("XILINX_VIVADO")):
        if cand and (Path(cand) / "bin").exists():
            return Path(cand) / "bin"
    exe = shutil.which("xvlog") or shutil.which("xvlog.bat")
    return Path(exe).parent if exe else None


def tool(bindir: Path, name: str) -> str:
    return str(bindir / (name + ".bat" if os.name == "nt" else name))


def run(cmd: list[str], cwd: Path, log: Path, timeout: int = 3600) -> str:
    with log.open("w") as fh:
        subprocess.run(cmd, cwd=cwd, stdout=fh, stderr=subprocess.STDOUT,
                       timeout=timeout, shell=(os.name == "nt"))
    return log.read_text(errors="ignore")


def simulate(sim: str | Path, work: Path, sources: list[Path], top: str) -> str:
    """Compile `sources` (with rtl/tb on the include path), elaborate `top`, run it in `work` and
    return the simulation log. `sim` is Vivado's bin/ directory, or "verilator"."""
    include = REPO / "rtl" / "tb"
    if sim == "verilator":
        out = run(["verilator", "--binary", "--timing", "-j", "0", "-Wno-fatal", "-Wno-WIDTH",
                   f"-I{include}", "--top-module", top, "-Mdir", "obj_dir"] + [str(s) for s in sources],
                  work, work / "verilator.log")
        exe = work / "obj_dir" / f"V{top}"
        if not exe.exists():
            err = re.search(r"(?m)^%Error.*", out)
            raise RuntimeError("build failed: " + (err.group(0) if err else "see verilator.log"))
        run([str(exe)], work, work / "sim.log")
        return (work / "sim.log").read_text(errors="ignore")
    out = run([tool(sim, "xvlog"), "-sv", "--include", str(include)] + [str(s) for s in sources],
              work, work / "xvlog.log")
    if re.search(r"(?m)^ERROR", out):
        raise RuntimeError("compile failed: " + re.search(r"(?m)^ERROR.*", out).group(0))
    out = run([tool(sim, "xelab"), top, "-s", "snap"], work, work / "xelab.log")
    if re.search(r"(?m)^ERROR", out):
        raise RuntimeError("elaboration failed: " + re.search(r"(?m)^ERROR.*", out).group(0))
    (work / "run.tcl").write_text("run all\nquit\n")
    run([tool(sim, "xsim"), "snap", "-tclbatch", "run.tcl", "-log", "sim.log"], work, work / "xsim.out")
    return (work / "sim.log").read_text(errors="ignore")


def python(script: Path, cwd: Path) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(script)], cwd=cwd, capture_output=True, text=True)


# ---------------------------------------------------------------------------
def check_equivalence() -> tuple[bool, str]:
    res = python(REPO / "golden_model" / "test_conv2d.py", REPO / "golden_model")
    m = re.search(r"All (\d+) equivalence cases passed", res.stdout)
    ok = res.returncode == 0 and m is not None and m.group(1) == "5"
    return ok, f"{m.group(1)}/5 cases match" if m else f"failed (exit {res.returncode})"


def check_network() -> tuple[bool, str]:
    res = python(REPO / "golden_model" / "run_network.py", REPO / "golden_model")
    acc = re.search(r"accuracy vs label\.npy:\s*(\d+)/(\d+)", res.stdout)
    agree = re.search(r"agreement vs output\.npy argmax:\s*(\d+)/(\d+)", res.stdout)
    if res.returncode != 0 or not acc or not agree:
        return False, f"failed (exit {res.returncode})"
    ok = acc.groups() == ("19", "20") and agree.groups() == ("19", "20")
    return ok, f"{acc.group(1)}/{acc.group(2)} correct, {agree.group(1)}/{agree.group(2)} agree with output.npy"


def check_vectors() -> tuple[bool, str]:
    # regenerate into a scratch copy of golden_model/ + tools/ + data/ so the committed files are untouched
    work = BUILD / "vectors"
    shutil.rmtree(work, ignore_errors=True)
    for d in ("golden_model", "tools", "data"):
        shutil.copytree(REPO / d, work / d, ignore=shutil.ignore_patterns("__pycache__"))
    (work / "rtl" / "tb").mkdir(parents=True)
    res = python(work / "tools" / "gen_tb_vectors.py", work)
    if res.returncode != 0:
        return False, f"gen_tb_vectors.py failed (exit {res.returncode})"
    names = ["vectors/ifm.mem", "vectors/weight.mem", "vectors/ofm_expected.mem", "tb_config.svh",
             "tb_top_cases.svh"]
    names += sorted(p.relative_to(work / "rtl" / "tb").as_posix()
                    for p in (work / "rtl" / "tb" / "vectors").glob("top_case*.mem"))
    norm = lambda p: p.read_bytes().replace(b"\r\n", b"\n")
    differ = [n for n in names if norm(work / "rtl" / "tb" / n) != norm(REPO / "rtl" / "tb" / n)]
    if differ:
        return False, "differs from gen_tb_vectors.py output: " + ", ".join(differ)
    return True, f"all {len(names)} committed files match gen_tb_vectors.py output"


def check_hdl(sim: str | Path, top: str, sources: list[str]) -> tuple[bool, str]:
    work = BUILD / top
    shutil.rmtree(work, ignore_errors=True)
    shutil.copytree(REPO / "rtl" / "tb" / "vectors", work / "vectors")
    log = simulate(sim, work, [REPO / "rtl" / s for s in sources], top)
    m = re.search(r"PASS: all (\d+) OFM words (of \d+ tiles )?match golden model", log)
    if m:
        return True, f"all {m.group(1)} OFM words {m.group(2) or ''}match the golden model"
    fail = re.search(r"(FAIL|TIMEOUT).*", log)
    return False, fail.group(0) if fail else "no PASS line in the simulation log"


# ---------------------------------------------------------------------------
def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--vivado", help="Vivado install directory (contains bin/xvlog)")
    ap.add_argument("--sim", choices=["xsim", "verilator"],
                    help="HDL simulator (default: xsim if Vivado is found, otherwise Verilator)")
    ap.add_argument("--skip-hdl", action="store_true", help="run only the Python checks")
    args = ap.parse_args()

    checks = [("Golden model equivalence", check_equivalence),
              ("Golden model network", check_network),
              ("Test vectors", check_vectors)]
    if not args.skip_hdl:
        bindir = find_vivado(args.vivado)
        choice = args.sim or ("xsim" if bindir else "verilator")
        if choice == "xsim" and bindir is None:
            sys.exit("xvlog not found: pass --vivado <install dir>, put Vivado's bin/ on PATH, "
                     "or use --sim verilator or --skip-hdl")
        if choice == "verilator" and not shutil.which("verilator"):
            sys.exit("verilator not found: install Verilator 5, pass --vivado <install dir>, or use --skip-hdl")
        sim = bindir if choice == "xsim" else "verilator"
        print(f"HDL simulator: {'Vivado xsim' if choice == 'xsim' else 'Verilator'}")
        checks += [("Conv engine", lambda: check_hdl(sim, "tb_conv_engine",
                                                     ["conv_engine.sv", "tb/tb_conv_engine.sv"])),
                   ("NPU top level", lambda: check_hdl(sim, "tb_npu_top",
                                                       ["conv_engine.sv", "npu_csr_axil.sv", "npu_top.sv",
                                                        "tb/tb_npu_top.sv"]))]

    BUILD.mkdir(parents=True, exist_ok=True)
    results = []
    for name, fn in checks:
        try:
            ok, note = fn()
        except Exception as exc:  # report and keep going so one failure doesn't hide the rest
            ok, note = False, str(exc)
        results.append(ok)
        print(f"{'PASS' if ok else 'FAIL'}  {name:26s} {note}", flush=True)

    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
