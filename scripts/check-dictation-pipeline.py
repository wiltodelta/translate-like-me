#!/usr/bin/env python3
"""Compare channel selection and finite resampling on synthetic speech, offline."""

import argparse
import array
from datetime import datetime, timezone
import hashlib
import json
import logging
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import wave

log = logging.getLogger(__name__)
ROOT = Path(__file__).resolve().parents[1]
ARMS = ("baseline", "channelOnly", "converterOnly", "candidate")


def save(file, value):
    pending = file.with_suffix(".pending")
    pending.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    pending.replace(file)


def run(arguments, *, env=None, timeout=1200, logfile=None):
    with (logfile or Path(os.devnull)).open("w") as output:
        child = subprocess.Popen([str(x) for x in arguments], cwd=ROOT, env=env,
                                 stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = child.wait(timeout=timeout)
        except BaseException:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()
            raise
    if code:
        raise RuntimeError("Subprocess exited %s; see %s" % (code, logfile))


def read(file):
    with wave.open(str(file), "rb") as stream:
        if stream.getsampwidth() != 2 or stream.getnchannels() != 1:
            raise RuntimeError("Unexpected synthetic source format")
        rate = stream.getframerate()
        values = array.array("h", stream.readframes(stream.getnframes()))
    if sys.byteorder != "little":
        values.byteswap()
    return rate, values


def write(file, rate, channels):
    length = len(channels[0])
    if any(len(x) != length for x in channels):
        raise RuntimeError("Mismatched channel lengths")
    samples = array.array("h", (int(channels[c][i]) for i in range(length) for c in range(len(channels))))
    if sys.byteorder != "little":
        samples.byteswap()
    with wave.open(str(file), "wb") as stream:
        stream.setparams((len(channels), 2, rate, 0, "NONE", "not compressed"))
        stream.writeframes(samples.tobytes())


def corpus(folder):
    russian = "Сегодня я проверяю микрофон наушников и хочу получить точный текст без ошибок."
    english = "The blue lantern is beside the window and the green notebook."
    examples = []
    for name, voice, text in [("ru", "Milena", russian), ("en", "Samantha", english)]:
        file = folder / (name + ".wav")
        run(["/usr/bin/say", "-v", voice, "-r", "155", "-o", folder / (name + ".aiff"), text], timeout=30)
        run(["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@48000", "-c", "1",
             folder / (name + ".aiff"), file], timeout=30)
        save(folder / (name + "-generated.json"), {"voice": voice, "rate": 48000})
    rate, ru = read(folder / "ru.wav")
    _, en = read(folder / "en.wav")

    def add(name, channels, text=russian, sample_rate=48000, channel=0, unchanged=False):
        filename = "source-" + name + ".wav"
        write(folder / filename, sample_rate, channels)
        examples.append(dict(id=name, file=filename, reference=text, channel=channel, unchangedInput=unchanged))
        save(folder / "generation-progress.json", {"completed": [x["id"] for x in examples]})

    add("russian", [ru])
    add("english", [en], text=english)
    for target in [16000, 24000, 8000]:
        file = folder / ("rate-" + str(target) + ".wav")
        run(["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@" + str(target), "-c", "1",
             folder / "ru.wav", file], timeout=30)
        actual_rate, values = read(file)
        add("russian-" + str(target), [values], sample_rate=actual_rate, unchanged=target == 16000)
    add("quiet", [[round(value * 0.05) for value in ru]])
    symmetric = [max(-32767, min(32767, value)) for value in ru]
    add("opposite", [symmetric, [-value for value in symmetric]])
    add("right-only", [[0] * len(ru), ru], channel=1)
    add("dc-channel", [[12000] * len(ru), ru], channel=1)
    add("silence", [[0] * (rate * 4)], text="")
    save(folder / "cases.json", examples)
    return examples


def words(text):
    return re.sub(r"[\W_]+", " ", text.lower().replace("ё", "е"), flags=re.UNICODE).split()


def distance(reference, actual):
    previous = list(range(len(actual) + 1))
    for index, expected in enumerate(reference, 1):
        current = [index]
        for offset, value in enumerate(actual, 1):
            current.append(min(current[-1] + 1, previous[offset] + 1,
                               previous[offset - 1] + (expected != value)))
        previous = current
    return previous[-1]


def summarize(folder, examples):
    rows = json.loads((folder / "comparison.json").read_text())
    models = json.loads((folder / "models.json").read_text())
    expected = {(model, arm, x["id"], repetition) for model in models for arm in ARMS
                for x in examples for repetition in range(1, 4)}
    actual = {(x["model"], x["arm"], x["id"], x["repetition"]) for x in rows}
    if actual != expected or len(rows) != len(expected):
        raise RuntimeError("Comparison has missing or duplicated results")
    for row in rows:
        row["wordErrors"] = distance(words(row["reference"]), words(row["text"]))
        row["referenceWords"] = len(words(row["reference"]))
        row["exactWords"] = words(row["reference"]) == words(row["text"])
    comparisons = []
    for model in models:
        improved = worsened = ties = 0
        for example in examples:
            totals = {arm: sum(x["wordErrors"] for x in rows if x["model"] == model and
                              x["id"] == example["id"] and x["arm"] == arm) for arm in ARMS}
            improved += totals["candidate"] < totals["baseline"]
            worsened += totals["candidate"] > totals["baseline"]
            ties += totals["candidate"] == totals["baseline"]
            comparisons.append(dict(model=model, id=example["id"], wordErrors=totals))
        count = improved + worsened
        probability = min(1, 2 * sum(math.comb(count, i) for i in range(min(improved, worsened) + 1)) / 2 ** count) if count else None
        log.info("%s: improved %s, worsened %s, tied %s cases; sign-test p=%s", model, improved, worsened, ties, probability)
    safe_rows = [{k: v for k, v in row.items() if k not in ("text", "reference")} for row in rows]
    regressions = [x for x in comparisons if x["wordErrors"]["candidate"] > x["wordErrors"]["baseline"]]
    failures = [x for x in safe_rows if x["arm"] == "candidate" and x["status"] != "recognized"]
    result = dict(status="failed" if regressions or failures else "passed",
                  cases=len(examples), rows=safe_rows, comparisons=comparisons,
                  regressions=regressions, candidateFailures=failures,
                  microphoneUsed=False, speakersUsed=False,
                  limits="Two synthetic voices; case variants share source speech; not a real-speaker accuracy estimate.")
    save(folder / "summary.json", result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, required=True, help="Task-owned unique temporary directory")
    parser.add_argument("--cache-source", type=Path, default=Path.home() / "Library/Application Support/com.wiltodelta.translatelikeme/Dictation")
    parser.add_argument("--metallib", type=Path, default=Path("/Applications/Translate Like Me.app/Contents/Resources/mlx.metallib"))
    args = parser.parse_args()
    folder = args.work.resolve()
    folder.mkdir(parents=True, exist_ok=True)
    code = 1
    try:
        examples = json.loads((folder / "cases.json").read_text()) if (folder / "cases.json").exists() else corpus(folder)
        if not (folder / "models").exists():
            run(["/bin/cp", "-cR", args.cache_source, folder / "models"], timeout=60)
            save(folder / "cache-cloned.json", {"source": str(args.cache_source), "writesToSource": False})
        paths = [Path(__file__), ROOT / "Sources/TranslateLikeMe/DictationAudioLoader.swift",
                 ROOT / "Sources/TranslateLikeMe/DictationEngine.swift",
                 ROOT / "Tests/TranslateLikeMeTests/DictationPipelineComparisonTests.swift"]
        signature = {str(file): hashlib.sha256(file.read_bytes()).hexdigest() for file in paths}
        signature.update({item["file"]: hashlib.sha256((folder / item["file"]).read_bytes()).hexdigest()
                          for item in examples})
        stamp = folder / "inputs.json"
        if stamp.exists() and json.loads(stamp.read_text()) != signature:
            raise RuntimeError("The benchmark source or fixtures changed; use a new work directory")
        save(stamp, signature)
        environment = {key: value for key, value in os.environ.items() if not key.startswith("TLM_")}
        environment.update(TLM_PIPELINE_COMPARISON=str(folder), TLM_QWEN_METALLIB=str(args.metallib.resolve()))
        log.info("Comparing %s synthetic cases, four loader arms, three repeats per model", len(examples))
        run(["swift", "test", "--filter", "DictationPipelineComparisonTests"], env=environment,
            logfile=folder / "test.log")
        result = summarize(folder, examples)
        log.info("Completed %s model/arm/case repetitions", len(result["rows"]))
        if result["status"] != "passed":
            raise RuntimeError("Candidate worsened a case or failed recognition; see summary.json")
        code = 0
    except Exception as error:
        log.exception("Pipeline comparison failed")
        save(folder / "failure.json", {"error": str(error)})
    finally:
        save(folder / "completion.json", {"exitCode": code, "finishedAt": datetime.now(timezone.utc).isoformat()})
    return code


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
    raise SystemExit(main())
