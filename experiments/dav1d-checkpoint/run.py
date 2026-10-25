"""Windows PC checkpoint proof. Media and build products stay under .local/."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
PIN = "54706fc6bc0cdecab7e9593974a4039cc038fca7"
SOURCE = ROOT / ".local/dav1d-checkpoint"
BUILD = SOURCE / "build"


def run(argv, env, log=None):
    command = [str(a) for a in argv]
    command[0] = shutil.which(command[0], path=env["PATH"]) or command[0]
    result = subprocess.run(command, cwd=ROOT, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if log:
        (ROOT / ".local" / log).write_bytes(result.stdout + result.stderr)
    if result.returncode:
        # Do not add private input names to the saved aggregate report.
        raise RuntimeError(result.stderr.decode("utf-8", errors="replace")[-4000:]
                           or result.stdout.decode("utf-8", errors="replace")[-4000:])
    return result.stdout.decode("utf-8")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--input", type=Path, help="Optional local long-GOP AV1 recording; never copied into tracked files")
    ap.add_argument("--toolchain", type=Path, default=Path("C:/msys64/mingw64/bin"))
    ap.add_argument("--ffmpeg", default=shutil.which("ffmpeg") or "C:/nyanzTV/ffmpeg-7.1.1-essentials_build/bin/ffmpeg.exe")
    ap.add_argument("--report", type=Path, default=ROOT / ".local/checkpoint-results.json")
    args = ap.parse_args()
    if os.name != "nt":
        ap.error("This harness currently uses Windows QueryPerformanceCounter")
    env = os.environ.copy()
    env["PATH"] = str(args.toolchain) + os.pathsep + env["PATH"]
    env["CC"] = str(args.toolchain / "gcc.exe")
    # GCC in this environment cannot create assembly objects in a Unicode TMP.
    temp = args.toolchain.parents[1] / "tmp/neo-dav1d-checkpoint"
    temp.mkdir(parents=True, exist_ok=True)
    env["TMP"] = env["TEMP"] = str(temp)
    (ROOT / ".local").mkdir(exist_ok=True)
    if not SOURCE.exists():
        run(["git", "clone", "--depth", "1", "--branch", "1.5.4",
             "https://github.com/videolan/dav1d.git", SOURCE], env, "checkpoint-clone.log")
    if run(["git", "-C", SOURCE, "rev-parse", "HEAD"], env).strip() != PIN:
        raise RuntimeError("Existing dav1d checkout does not match pinned source; refusing to overwrite")
    shutil.copyfile(HERE / "neo_checkpoint.h", SOURCE / "include/neo_checkpoint.h")
    shutil.copyfile(HERE / "checkpoint.c", SOURCE / "src/neo_checkpoint.c")
    meson = SOURCE / "src/meson.build"
    text = meson.read_text(encoding="utf-8")
    if "'neo_checkpoint.c'" not in text:
        anchor = "'cdf.c',"
        if text.count(anchor) != 1:
            raise RuntimeError("Unexpected upstream Meson layout")
        meson.write_bytes(text.replace(anchor, anchor + "\n    'neo_checkpoint.c',").encode())
    if not (BUILD / "build.ninja").exists():
        run(["meson", "setup", BUILD.relative_to(ROOT).as_posix(), SOURCE.relative_to(ROOT).as_posix(), "--buildtype=release",
             "--default-library=static", "-Db_ndebug=false", "-Denable_tools=false",
             "-Denable_tests=false", "-Denable_docs=false"], env, "checkpoint-setup.log")
    run(["ninja", "-C", BUILD, "-j", "8"], env, "checkpoint-build.log")
    exe = BUILD / "checkpoint-probe.exe"
    run(["gcc", "-std=gnu11", "-O2", "-g", "-Wall", "-Wextra", "-Werror",
         "-I.local/dav1d-checkpoint/include", "-I.local/dav1d-checkpoint/build/include",
         (HERE / "probe.c").relative_to(ROOT).as_posix(),
         (BUILD / "src/libdav1d.a").relative_to(ROOT).as_posix(),
         "-o", exe.relative_to(ROOT).as_posix(), "-lm"], env, "checkpoint-link.log")

    cases = [("fixture-8bit", ROOT / "tests/fixtures/av1-seek-8.mkv", [18]),
             ("fixture-10bit", ROOT / "tests/fixtures/av1-seek-10.mkv", [18])]
    if args.input:
        cases.append(("recording-10bit-long-gop", args.input.resolve(), [18, 19.8]))
    results = []
    for label, source, positions in cases:
        ivf = Path(".local") / ("checkpoint-" + label + ".ivf")
        run([args.ffmpeg, "-v", "error", "-y", "-i", source,
             "-map", "0:v:0", "-c:v", "copy", "-t", "32", "-f", "ivf", ivf], env)
        for cp in positions:
            print(f"Checking {label}, checkpoint={cp}s", flush=True)
            row = json.loads(run([exe, ivf, cp, 20, 30], env))
            row["case"] = label
            for name in ("restoreMs", "restoreAndSuffixMs", "fromKeyframeMs", "warmFromKeyframeMs"):
                row[name + "Median"] = statistics.median(row[name])
            row["retainedMiB"] = row["retainedBytes"] / 1024**2
            results.append(row)
    report = {
        "upstreamRevision": PIN,
        "compiler": run(["gcc", "--version"], env).splitlines()[0],
        "method": "Windows x86_64, one thread, input in RAM, decoded pictures only; no network/audio/UI",
        "sourceSha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                         for p in (HERE / "checkpoint.c", HERE / "neo_checkpoint.h", HERE / "probe.c")},
        "cases": results,
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_bytes((json.dumps(report, indent=2) + "\n").encode())
    print("All pixel comparisons passed; aggregate report saved.")


if __name__ == "__main__":
    main()
