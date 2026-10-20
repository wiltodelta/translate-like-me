#!/usr/bin/env python3
"""Validate Parakeet installation, offline reload and Whisper switching with synthetic speech."""

import argparse
import importlib.util
import json
import logging
import os
from pathlib import Path
import tempfile
import wave

log = logging.getLogger(__name__)
ROOT = Path(__file__).resolve().parents[1]


def helper(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), ROOT / "scripts" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--report", type=Path, default=ROOT / ".build/parakeet-check/report.json")
    args = parser.parse_args()
    args.report.parent.mkdir(parents=True, exist_ok=True)
    benchmark = helper("benchmark-dictation")
    audio = helper("check-dictation-audio")
    cache = benchmark.CACHE / "models/FluidInference/parakeet-ultra-coreml"
    report = {"status": "running", "microphoneUsed": False, "audioPlaybackUsed": False,
              "appModelCacheExistedBefore": cache.exists()}
    args.report.write_text(json.dumps(report, indent=2))
    folder = None
    try:
        with tempfile.TemporaryDirectory(prefix="tlm-parakeet-check-") as temporary:
            folder = Path(temporary)
            manifest = benchmark.corpus(folder)
            cases = json.loads(manifest.read_text())
            silence = folder / "silence.wav"
            with wave.open(str(silence), "wb") as target:
                target.setparams((1, 2, 16_000, 32_000, "NONE", "not compressed"))
                target.writeframes(bytes(64_000))
            cases.append(dict(id="silence", file=str(silence), expected="", terms=[]))
            manifest.write_text(json.dumps(cases, ensure_ascii=False))
            command = ["swift", "test"]
            if args.skip_build:
                command.append("--skip-build")
            command += ["--filter", "DictationParakeetTests"]
            log.info("Checking pinned installation, both runtimes and offline reloads")
            output = audio.run(command, env=dict(os.environ, TLM_PARAKEET_CHECK=str(folder)))
            args.report.with_suffix(".log").write_text(output)
            results = json.loads((folder / "parakeet-check.json").read_text())
            expected = {(preparation, case["id"], repetition) for preparation in range(3)
                        for case in cases for repetition in range(1, 4)}
            rows = results["rows"]
            if len(rows) != len(expected) or {(row["preparation"], row["id"], row["repetition"])
                                             for row in rows} != expected:
                raise RuntimeError("Incomplete runtime-switch coverage")
            if any(row["model"] != ["parakeetUltra", "turbo", "parakeetUltra"][row["preparation"]] or
                   row["matchedTerms"] != row["requiredTerms"] or row["empty"] != (row["id"] == "silence")
                   for row in rows):
                raise RuntimeError("Unexpected runtime or synthetic recognition result")
            if not all(results[key] for key in ["offlineReload", "unloaded", "cancelledPreparation"]):
                raise RuntimeError("Incomplete lifecycle verification")
            report.update(status="passed", **results)
            log.info("Passed %s synthetic recognitions, offline reload and cancellation", len(rows))
    except Exception as error:
        report.update(status="failed", reason=str(error))
        log.error("%s", error)
    finally:
        report["temporaryAudioRemoved"] = folder is None or not folder.exists()
        args.report.write_text(json.dumps(report, indent=2))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    raise SystemExit(main())
