"""Compare local ASR runtimes on pinned public recordings without microphone access."""

import argparse
import collections
import hashlib
import importlib.util
import io
import json
import logging
import os
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import sys
import tarfile
import time
import urllib.request

log = logging.getLogger(__name__)
ROOT = Path(__file__).resolve().parents[1]
FLEURS = "70bb2e84b976b7e960aa89f1c648e09c59f894dd"
PODLODKA = "4a9161485a70ea849ccaa54a72faa9bfc0a60627"
QWEN_REPO = "mlx-community/Qwen3-ASR-1.7B-8bit"
QWEN_REV = "a8379a2e2f9e313c9292cdf1af4055ab56d50d55"


def write(file, value):
    temporary = file.with_suffix(file.suffix + ".partial")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2))
    temporary.replace(file)


def fetch(url):
    with urllib.request.urlopen(url, timeout=90) as response:
        return response.read()


def download(url, target):
    partial = target.with_suffix(target.suffix + ".partial")
    log.info("Downloading public artifact %s", target.name)
    with urllib.request.urlopen(url, timeout=120) as response, partial.open("wb") as output:
        shutil.copyfileobj(response, output, 1024 * 1024)
    partial.replace(target)


def normalize(text):
    return re.sub(r"[\W_]+", " ", text.lower().replace("ё", "е"), flags=re.UNICODE).strip()


def corpus(out):
    import pyarrow.parquet as pq
    import soundfile as sf

    raw = out / "raw"
    raw.mkdir()
    cases = []
    seen = set()
    for language in ["ru_ru", "en_us"]:
        prefix = "https://huggingface.co/datasets/google/fleurs/resolve/" + FLEURS + "/data/" + language
        tsv = fetch(prefix + "/test.tsv").decode()
        (out / (language + "-test.tsv")).write_text(tsv)
        lines = [line.split("\t") for line in tsv.splitlines()]
        lines.sort(key=lambda row: hashlib.sha256(row[1].encode()).hexdigest())
        selected = {}
        references = set()
        for row in lines:
            if row[0] in references:
                continue
            references.add(row[0])
            selected[row[1]] = row
            if len(selected) == 41:
                break
        archive = raw / (language + ".tar.gz")
        download(prefix + "/audio/test.tar.gz", archive)
        found = set()
        with tarfile.open(archive, mode="r|gz") as source:
            for member in source:
                name = Path(member.name).name
                if not member.isfile() or name not in selected:
                    continue
                data = source.extractfile(member).read()
                digest = hashlib.sha256(data).hexdigest()
                if digest in seen:
                    raise RuntimeError("Duplicate selected audio")
                seen.add(digest)
                file = raw / name
                file.write_bytes(data)
                row = selected[name]
                found.add(name)
                cases.append(dict(id=language + "-" + row[0] + "-" + name[:-4], file=str(file),
                    expected=row[2], group="fleurs-" + language, audioSha256=digest,
                    source="google/fleurs", revision=FLEURS, sourceFile=name, gender=row[6]))
        if found != set(selected):
            raise RuntimeError("Missing selected FLEURS audio")
        archive.unlink()
    parquet = raw / "podlodka.parquet"
    download("https://huggingface.co/datasets/bond005/podlodka_speech/resolve/" + PODLODKA +
             "/data/test-00000-of-00001.parquet", parquet)
    for index, row in enumerate(pq.read_table(parquet).to_pylist()):
        data = row["audio"]["bytes"]
        digest = hashlib.sha256(data).hexdigest()
        if digest in seen:
            raise RuntimeError("Duplicate Podlodka audio")
        seen.add(digest)
        samples, rate = sf.read(io.BytesIO(data), dtype="float32")
        file = raw / ("podlodka-%s.wav" % index)
        sf.write(file, samples, rate, subtype="FLOAT")
        cases.append(dict(id="podlodka-%s" % index, file=str(file), expected=row["transcription"],
            group="podlodka-ru", audioSha256=digest, source="bond005/podlodka_speech",
            revision=PODLODKA, episode=row["episode"]))
    parquet.unlink()
    # Fixed audio-hash selection above is independent of model output. One clip
    # per FLEURS language is calibration only; no scored sentence is repeated.
    calibration = []
    for group in ["fleurs-ru_ru", "fleurs-en_us"]:
        selected = next(case for case in cases if case["group"] == group)
        cases.remove(selected)
        selected["group"] = "calibration"
        calibration.append(selected)
    cases = calibration + sorted(cases, key=lambda case: hashlib.sha256(case["id"].encode()).hexdigest())
    write(out / "corpus.json", cases)
    return cases


def qwen_worker(out, manifest, destination):
    import mlx.core as mx
    import soundfile as sf
    from mlx_audio.stt import load

    cases = json.loads(manifest.read_text())
    start = time.perf_counter()
    model = load(str(out / "qwen-model"))
    mx.synchronize()
    report = dict(model="qwen", loadSeconds=time.perf_counter() - start, rows=[])
    for case in cases:
        began = time.perf_counter()
        samples, rate = sf.read(case["file"], dtype="float32")
        assert rate == 16000 and samples.ndim == 1
        audio_load = time.perf_counter() - began
        mx.synchronize()
        inference = time.perf_counter()
        result = model.generate(samples, language=None, max_tokens=1024, temperature=0.0, verbose=False) if case["speech"] else None
        mx.synchronize()
        report["rows"].append(dict(case=case["id"], text=result.text if result else "",
            audioLoadSeconds=audio_load, inferenceSeconds=time.perf_counter() - inference,
            totalSeconds=time.perf_counter() - began))
        write(destination, report)
        log.info("Qwen completed %s (%s/%s)", case["id"], len(report["rows"]), len(cases))


def summarize(out):
    import jiwer
    import math
    import random

    cases = {case["id"]: case for case in json.loads((out / "prepared.json").read_text())}
    summary = dict(groups={}, paired={}, completeness={})
    all_rows = {}
    for model in ["qwen", "largeV3", "turbo", "ultra"]:
        rows = []
        for run in range(2):
            report = json.loads((out / ("round-%s-%s.json" % (run, model))).read_text())
            assert len(report["rows"]) == len(cases)
            assert {row["case"] for row in report["rows"]} == set(cases)
            rows.append({row["case"]: row for row in report["rows"]})
        scored = {}
        for identifier, case in cases.items():
            if case["group"] == "calibration":
                continue
            ref = normalize(case["expected"])
            hyp = normalize(rows[0][identifier]["text"])
            alignment = jiwer.process_words(ref, hyp)
            scored[identifier] = dict(errors=alignment.substitutions + alignment.deletions + alignment.insertions,
                referenceWords=len(ref.split()), deletions=alignment.deletions, insertions=alignment.insertions,
                substitutions=alignment.substitutions, cer=jiwer.cer(ref, hyp),
                stable=hyp == normalize(rows[1][identifier]["text"]), empty=not hyp,
                inference=[rows[run][identifier]["inferenceSeconds"] for run in range(2)],
                textHash=hashlib.sha256(rows[0][identifier]["text"].encode()).hexdigest())
        all_rows[model] = scored
        summary["completeness"][model] = dict(scoredClips=len(scored), completed=len(cases) * 2,
            normalizedChanges=sum(not row["stable"] for row in scored.values()))
        summary["groups"][model] = {}
        for group in sorted(set(case["group"] for case in cases.values()) - {"calibration"}):
            ids = [identifier for identifier, case in cases.items() if case["group"] == group]
            rr = [scored[identifier] for identifier in ids]
            times = [statistics.median(row["inference"]) for row in rr]
            words = sum(row["referenceWords"] for row in rr)
            errors = sum(row["errors"] for row in rr)
            summary["groups"][model][group] = dict(clips=len(ids), referenceWords=words, errors=errors,
                wer=errors / words, medianInferenceSeconds=statistics.median(times),
                p95InferenceSeconds=sorted(times)[min(len(times)-1, math.ceil(.95 * len(times))-1)],
                medianAudioSeconds=statistics.median(cases[identifier]["audioSeconds"] for identifier in ids),
                empty=sum(row["empty"] for row in rr), deletions=sum(row["deletions"] for row in rr))
        for run in range(2):
            report_file = out / ("round-%s-%s.json" % (run, model))
            report = json.loads(report_file.read_text())
            for row in report["rows"]:
                row.pop("text", None)
            write(report_file, report)
    for model in ["largeV3", "turbo", "ultra"]:
        for group in sorted(summary["groups"][model]):
            ids = [identifier for identifier, case in cases.items() if case["group"] == group]
            deltas = [all_rows["qwen"][identifier]["errors"]-all_rows[model][identifier]["errors"] for identifier in ids]
            wins = sum(d < 0 for d in deltas)
            losses = sum(d > 0 for d in deltas)
            n = wins + losses
            p = min(1.0, 2 * sum(math.comb(n, k) for k in range(min(wins, losses)+1)) / 2**n) if n else 1.0
            randomizer = random.Random(20261020)
            differences = []
            for _ in range(10000):
                sampled = [randomizer.choice(ids) for _ in ids]
                differences.append(sum(all_rows["qwen"][i]["errors"]-all_rows[model][i]["errors"] for i in sampled)
                    / sum(all_rows[model][i]["referenceWords"] for i in sampled))
            differences.sort()
            summary["paired"][model+"/"+group] = dict(qwenWins=wins, qwenLosses=losses,
                ties=len(ids)-n, signTestP=p, qwenMinusModelWerCI95=[differences[250], differences[9750]])
    write(out / "per-item-metrics.json", all_rows)
    write(out / "summary.json", summary)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--qwen-worker", type=Path)
    parser.add_argument("--resume-setup", action="store_true")
    args = parser.parse_args()
    out = args.output.resolve()
    if args.qwen_worker:
        qwen_worker(out, out / "prepared.json", args.qwen_worker)
        return
    out.mkdir(exist_ok=True, parents=True)
    if (out / "metadata.json").exists() and not args.resume_setup:
        raise RuntimeError("Output already contains a run")
    spec = importlib.util.spec_from_file_location("benchmark_parakeet", ROOT / "scripts/benchmark-parakeet.py")
    existing = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(existing)
    bench = existing.benchmark
    metadata = dict(status="preparing", started=time.time(), microphoneUsed=False, userRecordingsUsed=False,
        sourceCommit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        hardware=subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string", "hw.memsize"], text=True),
        sourceHashes={str(file.relative_to(ROOT)): hashlib.sha256(file.read_bytes()).hexdigest()
            for file in [*bench.SOURCES, Path(__file__), ROOT / "scripts/NaturalASRBenchmark.swift"]},
        qwenRepo=QWEN_REPO, qwenRevision=QWEN_REV, processNice=os.getpriority(os.PRIO_PROCESS, 0))
    write(out / "metadata.json", metadata)
    try:
        if not (args.resume_setup and (out / "corpus.json").exists()):
            corpus(out)
        else:
            for case in json.loads((out / "corpus.json").read_text()):
                if case["source"] == "google/fleurs":
                    assert hashlib.sha256(Path(case["file"]).read_bytes()).hexdigest() == case["audioSha256"]
        binary, metadata["signer"] = bench.build(out, entrypoint=ROOT / "scripts/NaturalASRBenchmark.swift")
        metadata["binarySha256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
        from huggingface_hub import snapshot_download
        snapshot_download(QWEN_REPO, revision=QWEN_REV, local_dir=out / "qwen-model")
        model_metadata = json.loads(fetch("https://huggingface.co/api/models/"+QWEN_REPO+"/revision/"+QWEN_REV+"?blobs=true"))
        for entry in model_metadata["siblings"]:
            if not existing.valid(out / "qwen-model" / entry["rfilename"], entry):
                raise RuntimeError("Invalid Qwen artifact: " + entry["rfilename"])
        write(out / "qwen-manifest.json", model_metadata)
        existing.download_models(Path.home() / "Library/Caches/com.wiltodelta.translatelikeme.dev/ParakeetUltra" / existing.MODEL_REVISION, out)
        with (out / "export.log").open("w") as output:
            bench.run([binary, "export", bench.CACHE, out / "corpus.json", "unused", out / "prepared.json"], log_file=output)
        prepared = json.loads((out / "prepared.json").read_text())
        metadata["speechGateRejected"] = [case["id"] for case in prepared if not case["speech"]]
        metadata["groups"] = dict(collections.Counter(case["group"] for case in prepared))
        subprocess.run(["uv", "pip", "freeze", "--python", sys.executable], stdout=(out / "requirements.txt").open("w"), check=True)
        # Round order reverses all four arms. Inference is strictly serial.
        metadata["status"] = "measuring"
        write(out / "metadata.json", metadata)
        for round_index, models in enumerate([["qwen", "largeV3", "turbo", "ultra"], ["ultra", "turbo", "largeV3", "qwen"]]):
            for model in models:
                stem = out / ("round-%s-%s" % (round_index, model))
                log.info("Starting %s", stem.name)
                command = [sys.executable, Path(__file__), "--output", out, "--qwen-worker", stem.with_suffix(".json")] if model == "qwen" else [binary, model, bench.CACHE, out / "prepared.json", Path.home() / "Library/Caches/com.wiltodelta.translatelikeme.dev/ParakeetUltra" / existing.MODEL_REVISION, stem.with_suffix(".json")]
                with stem.with_suffix(".log").open("w") as output:
                    bench.run(command, timeout=3600, log_file=output)
                log.info("Finished %s", stem.name)
        summarize(out)
        metadata["status"] = "complete"
    except BaseException as error:
        metadata.update(status="failed", error=str(error))
        raise
    finally:
        metadata["finished"] = time.time()
        write(out / "metadata.json", metadata)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    main()
