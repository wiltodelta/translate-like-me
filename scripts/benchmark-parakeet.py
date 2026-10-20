#!/usr/bin/env python3
"""Compare pinned Parakeet Ultra and current Whisper Turbo on synthetic audio."""

import argparse
import hashlib
import importlib.util
import json
import logging
import os
from pathlib import Path
import signal
import shutil
import subprocess
import tempfile
import time
import urllib.request
import wave

log = logging.getLogger(__name__)
ROOT = Path(__file__).resolve().parents[1]
MODEL_REPO = "FluidInference/parakeet-ultra-coreml"
MODEL_REVISION = "95eaa59a39d4394f047a4dc5cce480388a60d1b6"
spec = importlib.util.spec_from_file_location("whisper_benchmark", ROOT / "scripts/benchmark-dictation.py")
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)


def fetch(url):
    with urllib.request.urlopen(url, timeout=60) as response:
        return response.read()


def valid(file, entry):
    if not file.is_file() or file.stat().st_size != entry["size"]:
        return False
    if entry.get("lfs"):
        with file.open("rb") as source:
            digest = hashlib.file_digest(source, "sha256").hexdigest()
        return digest == entry["lfs"]["sha256"]
    data = file.read_bytes()
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest() == entry["blobId"]


def download_models(folder, output):
    metadata = json.loads(fetch("https://huggingface.co/api/models/%s/revision/%s?blobs=true" %
                                (MODEL_REPO, MODEL_REVISION)))
    assert metadata["sha"] == MODEL_REVISION
    (output / "model-manifest.json").write_text(json.dumps(metadata, indent=2))
    entries = [entry for entry in metadata["siblings"] if
               ".mlmodelc/" in entry["rfilename"] or entry["rfilename"] in
               {"parakeet_vocab.json", "parakeet_v3_vocab.json", "config.json", "README.md"}]
    for entry in entries:
        name = entry["rfilename"]
        file = folder / name
        if valid(file, entry):
            continue
        file.parent.mkdir(parents=True, exist_ok=True)
        log.info("Downloading %s (%s bytes)", name, entry["size"])
        partial = file.with_name(file.name + ".partial")
        try:
            with urllib.request.urlopen("https://huggingface.co/%s/resolve/%s/%s" %
                                        (MODEL_REPO, MODEL_REVISION, name), timeout=60) as response:
                with partial.open("wb") as target:
                    shutil.copyfileobj(response, target, 1024 * 1024)
            if not valid(partial, entry):
                raise RuntimeError("Model integrity check failed: " + name)
            partial.replace(file)
        finally:
            partial.unlink(missing_ok=True)
    return sum(entry["size"] for entry in entries)


def build(output):
    return benchmark.build(output, entrypoint=ROOT / "scripts/ParakeetBenchmark.swift")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--models", type=Path, default=Path.home() /
                        "Library/Caches/com.wiltodelta.translatelikeme.dev/ParakeetUltra" / MODEL_REVISION)
    parser.add_argument("--whisper-cache", type=Path, default=benchmark.CACHE)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    metadata = {"status": "running", "started": time.time(), "sdkRevision": benchmark.runtime_pins()["fluidaudio"]["state"]["revision"],
                "modelRevision": MODEL_REVISION, "modelCache": str(args.models),
                "microphoneUsed": False, "audioPlaybackUsed": False,
                "processNice": os.getpriority(os.PRIO_PROCESS, 0),
                "hardware": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string", "hw.memsize"], text=True),
                "sourceHashes": {str(file.relative_to(ROOT)): hashlib.sha256(file.read_bytes()).hexdigest()
                                 for file in [*benchmark.SOURCES, Path(__file__).resolve(),
                                              ROOT / "scripts/ParakeetBenchmark.swift"]}}
    (output / "metadata.json").write_text(json.dumps(metadata, indent=2))
    try:
        metadata["modelBytes"] = download_models(args.models, output)
        binary, metadata["signer"] = build(output)
        metadata["binarySha256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
        with tempfile.TemporaryDirectory(prefix="tlm-parakeet-comparison-") as temporary:
            folder = Path(temporary)
            manifest = benchmark.corpus(folder)
            cases = json.loads(manifest.read_text())
            mixed = "Сегодня проверим GitHub pull request, затем обновим release notes и отправим результат завтра утром."
            mixed_file = folder / "mixed.aiff"
            benchmark.run(["say", "-v", "Milena", "-r", "180", "-o", mixed_file, mixed], timeout=30)
            cases.append(dict(id="mixed", file=str(mixed_file), terms=["GitHub", "pull request", "release notes", "завтра"],
                              expected=mixed))
            silence = folder / "silence.wav"
            with wave.open(str(silence), "wb") as audio:
                audio.setparams((1, 2, 16_000, 32_000, "NONE", "not compressed"))
                audio.writeframes(bytes(64_000))
            cases.append(dict(id="silence", file=str(silence), terms=[], expected=""))
            manifest.write_text(json.dumps(cases, ensure_ascii=False, indent=2))
            metadata["corpus"] = [dict(id=case["id"], expected=case["expected"], terms=case["terms"],
                                      audioSha256=hashlib.sha256(Path(case["file"]).read_bytes()).hexdigest())
                                  for case in cases]
            # Validate pinned production assets through the real engine before either arm.
            with (output / "prepare.log").open("w") as log_file:
                benchmark.run([binary, "turbo", "prepare", args.whisper_cache, manifest, "1",
                               output / "prepare.json"], log_file=log_file)
            for round_index, arms in enumerate([["turbo", "ultra"], ["ultra", "turbo"]]):
                for arm in arms:
                    prefix = output / ("round-%s-%s" % (round_index, arm))
                    log.info("Starting round %s %s", round_index, arm)
                    model_path = args.models if arm == "ultra" else "ane"
                    with prefix.with_suffix(".log").open("w") as log_file:
                        benchmark.run([binary, arm, model_path, args.whisper_cache, manifest, "3",
                                       prefix.with_suffix(".json")], log_file=log_file)
                    rows = json.loads(prefix.with_suffix(".json").read_text())["rows"]
                    expected = {(case["id"], iteration) for case in cases for iteration in range(4)}
                    if len(rows) != len(expected) or {(row["case"], row["iteration"]) for row in rows} != expected:
                        raise RuntimeError("Incomplete comparison rows")
                    if any(row["speech"] != (row["case"] != "silence") for row in rows):
                        raise RuntimeError("Speech gate did not reach the intended scenario")
                    log.info("Finished %s: %s rows, %s with missing terms", arm, len(rows),
                             sum(bool(row["missingTerms"]) for row in rows))
        metadata["status"] = "complete"
    except BaseException as error:
        metadata.update(status="failed", error=str(error))
        raise
    finally:
        metadata["finished"] = time.time()
        metadata["temporaryAudioRemoved"] = True
        (output / "metadata.json").write_text(json.dumps(metadata, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    def interrupted(_number, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    main()
