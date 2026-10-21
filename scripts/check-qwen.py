#!/usr/bin/env python3
"""Validate Qwen installation, offline reload and Whisper switching with synthetic speech."""

import argparse
import importlib.util
import json
import logging
import os
from pathlib import Path
import tempfile
import threading
from http.server import ThreadingHTTPServer
from urllib.request import urlopen
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
    parser.add_argument("--report", type=Path, default=ROOT / ".build/qwen-check/report.json")
    args = parser.parse_args()
    args.report.parent.mkdir(parents=True, exist_ok=True)
    benchmark = helper("benchmark-dictation")
    audio = helper("check-dictation-audio")
    cache = benchmark.CACHE / "models/mlx-community/Qwen3-ASR-1.7B-8bit"
    report = {"status": "running", "microphoneUsed": False, "audioPlaybackUsed": False,
              "appModelCacheExistedBefore": cache.exists()}
    args.report.write_text(json.dumps(report, indent=2))
    folder = None
    try:
        with tempfile.TemporaryDirectory(prefix="tlm-qwen-check-") as temporary:
            folder = Path(temporary)
            worker_temp = folder / "worker-tmp"
            worker_temp.mkdir()
            manifest = benchmark.corpus(folder)
            cases = json.loads(manifest.read_text())
            for case in cases:
                if case["id"] == "en-long":
                    case["terms"] += ["independently", "recordings", "memory", "mistakes"]
                if case["id"] == "ru-long":
                    case["terms"] += ["распознавания", "записи", "памяти", "ошибки"]
            silence = folder / "silence.wav"
            with wave.open(str(silence), "wb") as target:
                target.setparams((1, 2, 16_000, 32_000, "NONE", "not compressed"))
                target.writeframes(bytes(64_000))
            cases.append(dict(id="silence", file=str(silence), expected="", terms=[]))
            manifest.write_text(json.dumps(cases, ensure_ascii=False))
            command = ["swift", "test"]
            if args.skip_build:
                command.append("--skip-build")
            command += ["--filter", "DictationQwenIntegrationTests/testQwenDownloadsRecognizesAndSwitchesBackToWhisper"]
            log.info("Checking pinned installation, both runtimes and offline reloads")
            output = audio.run(command, env=dict(os.environ, TMPDIR=str(worker_temp), TLM_QWEN_CHECK=str(folder),
                TLM_QWEN_METALLIB=str(ROOT / "Translate Like Me.app/Contents/Resources/mlx.metallib")), timeout=1800)
            args.report.with_suffix(".log").write_text(output)
            results = json.loads((folder / "qwen-check.json").read_text())
            expected = {(preparation, case["id"], repetition) for preparation in range(3)
                        for case in cases for repetition in range(1, 4)}
            rows = results["rows"]
            if len(rows) != len(expected) or {(row["preparation"], row["id"], row["repetition"])
                                             for row in rows} != expected:
                raise RuntimeError("Incomplete runtime-switch coverage")
            if any(row["model"] != ["qwen3ASR", "turbo", "qwen3ASR"][row["preparation"]] or
                   row["matchedTerms"] != row["requiredTerms"] or row["empty"] != (row["id"] == "silence")
                   for row in rows):
                raise RuntimeError("Unexpected runtime or synthetic recognition result")
            if not all(results[key] for key in ["offlineReload", "unloaded", "cancelledPreparation"]):
                raise RuntimeError("Incomplete lifecycle verification")
            report.update(**results)
            handler = helper("check-fresh-install").CanaryHandler
            with ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                endpoint = "http://127.0.0.1:%s/" % server.server_port
                try:
                    with urlopen(endpoint, timeout=3) as response:
                        assert response.read() == b"synthetic network sentinel"
                    offline = ["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)(deny network*)",
                               "swift", "test", "--disable-sandbox", "--skip-build", "--filter",
                               "DictationQwenIntegrationTests/testOfflineReloadWithoutNetwork"]
                    offline_output = audio.run(offline, env=dict(os.environ, TMPDIR=str(worker_temp), TLM_QWEN_CHECK=str(folder),
                        TLM_QWEN_OFFLINE_ENDPOINT=endpoint,
                        TLM_QWEN_METALLIB=str(ROOT / "Translate Like Me.app/Contents/Resources/mlx.metallib")), timeout=600)
                    args.report.with_suffix(".offline.log").write_text(offline_output)
                    with urlopen(endpoint, timeout=3) as response:
                        assert response.read() == b"synthetic network sentinel"
                finally:
                    server.shutdown()
                    thread.join()
            if (folder / "offline-verified.txt").read_text() != "verified":
                raise RuntimeError("Offline model did not complete the sandboxed recognition")
            report.update(status="passed", networkDeniedOfflineReload=True, **results)
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
