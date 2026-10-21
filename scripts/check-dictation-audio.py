#!/usr/bin/env python3
"""Run synthetic post-processing audio checks without desktop input or physical recording."""

import argparse
import array
import json
import logging
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import wave

log = logging.getLogger(__name__)
ROOT = Path(__file__).resolve().parents[1]
RATE = 48_000
# First-use ANE specialization can recur in the XCTest host even after a CLI
# benchmark prepared the same cache. Bound preparation and recognition together.
CHECK_TIMEOUT = 600


def run(arguments, *, env=None, timeout=CHECK_TIMEOUT):
    child = subprocess.Popen([str(item) for item in arguments], cwd=ROOT, env=env,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                             start_new_session=True)
    try:
        output, _ = child.communicate(timeout=timeout)
    except BaseException:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.communicate()
        raise
    if child.returncode:
        raise RuntimeError("Audio validation subprocess failed (%s):\n%s" % (child.returncode, output))
    return output


def read_pcm(file):
    with wave.open(str(file), "rb") as source:
        if (source.getnchannels(), source.getsampwidth(), source.getframerate()) != (1, 2, RATE):
            raise RuntimeError("Synthetic audio has an unexpected PCM format")
        samples = array.array("h", source.readframes(source.getnframes()))
    if sys.byteorder != "little":
        samples.byteswap()
    if not samples or not any(samples):
        raise RuntimeError("The synthetic speech generator returned empty audio")
    return samples


def write_pcm(file, samples):
    values = array.array("h", samples)
    if sys.byteorder != "little":
        values.byteswap()
    with wave.open(str(file), "wb") as output:
        output.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
        output.writeframes(values.tobytes())


def corpus(folder):
    samples = []
    for name, voice, text, terms in [
        ("english", "Samantha", "Cobalt lantern marble cactus orbit violin.",
         ["cobalt", "lantern", "marble", "cactus", "orbit", "violin"]),
        ("russian", "Milena (Russian (Russia))", "Синяя лодка плывёт по реке. Рядом растут высокие деревья.",
         ["синяя", "лодка", "плывет", "реке", "растут", "деревья"]),
    ]:
        run(["/usr/bin/say", "-v", voice, "-r", "155", "-o", folder / (name + ".aiff"), text], timeout=30)
        run(["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@48000", "-c", "1",
             folder / (name + ".aiff"), folder / (name + ".wav")], timeout=30)
        read_pcm(folder / (name + ".wav"))
        samples.append({"id": name, "file": name + ".wav", "terms": terms, "expectEmpty": False})
    foreground = read_pcm(folder / "russian.wav")
    background = read_pcm(folder / "english.wav")
    # Simulated residual background is mixed after the untested echo canceller.
    mixed = [max(-32768, min(32767, round(0.8 * value + 0.08 * background[i % len(background)])))
             for i, value in enumerate(foreground)]
    write_pcm(folder / "mixed.wav", mixed)
    samples.append({"id": "mixed", "file": "mixed.wav", "terms": samples[1]["terms"], "expectEmpty": False})
    write_pcm(folder / "silence.wav", [0] * (RATE * 4))
    samples.append({"id": "silence", "file": "silence.wav", "terms": [], "expectEmpty": True})
    (folder / "cases.json").write_text(json.dumps(samples, ensure_ascii=False, indent=2) + "\n")


def validate_results(cases, rows):
    expected = {(sample["id"], repetition) for sample in cases for repetition in range(1, 4)}
    actual = {(row["id"], row["repetition"]) for row in rows}
    if not expected or actual != expected or len(rows) != len(expected):
        raise RuntimeError("Recognition results do not cover every generated case three times")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true", help="Reuse a test bundle that includes this check")
    parser.add_argument("--report", type=Path, default=ROOT / ".build/dictation-audio-check/report.json")
    parser.add_argument("--model", choices=["small", "turbo", "largeV3", "qwen3ASR"], default="turbo")
    args = parser.parse_args()
    args.report.parent.mkdir(parents=True, exist_ok=True)
    report = {"status": "failed", "microphoneUsed": False, "speakersUsed": False,
              "voiceProcessingTested": False, "physicalVoicePreservation": "not tested",
              "model": args.model,
              "scope": "Native WAV sink, resampling, speech detection and cached model recognition"}
    args.report.write_text(json.dumps(dict(report, status="running"), indent=2) + "\n")
    folder = None
    try:
        with tempfile.TemporaryDirectory(prefix="tlm-synthetic-audio-") as temporary:
            folder = Path(temporary)
            log.info("Generating synthetic fixtures without playback or microphone access")
            corpus(folder)
            environment = dict(os.environ, TLM_AUDIO_CHECK=str(folder), TLM_AUDIO_CHECK_MODEL=args.model)
            command = ["swift", "test"]
            if args.skip_build:
                command.append("--skip-build")
            command += ["--filter", "DictationAudioValidationTests"]
            log.info("Running the native WAV and recognition checks, subprocess deadline %s seconds", CHECK_TIMEOUT)
            output = run(command, env=environment)
            args.report.with_suffix(".log").write_text(output)
            rows = json.loads((folder / "recognition.json").read_text())
            cases = json.loads((folder / "cases.json").read_text())
            validate_results(cases, rows)
            report.update(status="passed", recognition=rows)
            log.info("Synthetic audio: %s cases, three recognitions each, passed", len(cases))
    except Exception as error:
        log.error("%s", error)
        report["reason"] = str(error)
    finally:
        report["temporaryAudioRemoved"] = folder is None or not folder.exists()
        args.report.write_text(json.dumps(report, indent=2) + "\n")
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    def interrupted(_number, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
    raise SystemExit(main())
