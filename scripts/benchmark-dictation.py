#!/usr/bin/env python3
"""Compare cached Whisper compute configurations serially using synthetic speech."""

import argparse
import hashlib
import json
import logging
import os
from pathlib import Path
import re
import signal
import shutil
import subprocess
import tempfile
import time

log = logging.getLogger(__name__)
ROOT = Path(__file__).resolve().parents[1]
CACHE = Path.home() / "Library/Application Support/com.wiltodelta.translatelikeme.dev/Dictation"
SOURCES = [ROOT / "scripts/DictationBenchmark.swift"] + [
    ROOT / "Sources/TranslateLikeMe" / (name + ".swift") for name in
    ["DictationEngine", "DictationModel", "DictationSnapshot", "DictationSpeechDetector",
     "DictationQwen", "DictationQwenDecoding", "Logging"]
]


def run(arguments, *, timeout=600, log_file=None):
    child = subprocess.Popen([str(item) for item in arguments], cwd=ROOT,
                             stdout=log_file, stderr=subprocess.STDOUT, start_new_session=True)
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
        raise RuntimeError("Subprocess exited %s: %s" % (code, arguments[0]))


def corpus(folder, stress=False):
    english = ("We reviewed the project and checked the latest changes. "
               "The translation works locally and keeps the selected writing style. "
               "Please save the final report and send the updated version tomorrow morning. "
               "Before finishing, check the names and numbers carefully. ")
    russian = ("Мы проверили проект и последние изменения. Перевод работает локально "
               "и сохраняет выбранный стиль текста. Пожалуйста, сохрани окончательный отчёт "
               "и отправь обновлённую версию завтра утром. Перед завершением внимательно "
               "проверь имена и числа. ")
    english_message = (english + "The design review raised three questions about the settings window. "
                       "First, the language selection should remain visible when the window becomes narrow. "
                       "Second, a failed download needs a clear retry button and an explanation. "
                       "Third, the microphone must stop recording as soon as the key is released. "
                       "We can verify these behaviors independently before changing the recognition model. "
                       "For the next experiment, compare the same recordings on the same computer. "
                       "Record processing time and memory use separately from the time spent loading files. "
                       "Keep every result, including mistakes, so the comparison remains useful.")
    russian_message = (russian + "При обсуждении интерфейса возникли три вопроса об окне настроек. "
                       "Во-первых, выбор языка должен оставаться видимым в узком окне. "
                       "Во-вторых, при ошибке загрузки нужны понятное объяснение и кнопка повтора. "
                       "В-третьих, микрофон должен прекращать запись сразу после отпускания клавиши. "
                       "Эти условия можно проверить независимо от выбора модели распознавания. "
                       "В следующем эксперименте сравним одинаковые записи на одном компьютере. "
                       "Время обработки и расход памяти измерим отдельно от загрузки файлов. "
                       "Сохраним все результаты, включая ошибки, чтобы сравнение оставалось полезным.")
    cases = []
    for name, voice, text, terms in [
        ("en-short", "Samantha", "Please send the updated report tomorrow morning.", ["report", "tomorrow"]),
        ("ru-short", "Milena", "Пожалуйста, отправь обновлённый отчёт завтра утром.", ["отчёт", "завтра"]),
        ("en-long", "Samantha", english * 3 if stress else english_message,
         ["project", "translation", "tomorrow", "numbers"]),
        ("ru-long", "Milena", russian * 3 if stress else russian_message,
         ["проект", "перевод", "завтра", "числа"]),
    ]:
        file = folder / (name + ".aiff")
        run(["/usr/bin/say", "-v", voice, "-r", "180", "-o", file, text], timeout=30)
        cases.append(dict(id=name, file=str(file), terms=terms, expected=text))
    manifest = folder / "cases.json"
    manifest.write_text(json.dumps(cases, ensure_ascii=False, indent=2))
    return manifest


def validate(report, cases, repetitions):
    expected = {(case["id"], iteration) for case in cases for iteration in range(repetitions + 1)}
    rows = report.get("rows", [])
    actual = {(row["case"], row["iteration"]) for row in rows}
    if actual != expected or len(rows) != len(expected):
        raise RuntimeError("Incomplete or duplicated benchmark rows")
    if any(not row["speech"] or row["referenceWords"] <= 0 for row in rows):
        raise RuntimeError("Synthetic speech did not reach recognition")
    # Quality differences remain measurements, never silently filtered out.
    return sum(bool(row["missingTerms"]) for row in rows)


def runtime_pins():
    pins = json.loads((ROOT / "Package.resolved").read_text())["pins"]
    required = ["argmax-oss-swift", "mlx-audio-swift", "mlx-swift", "swift-collections"]
    result = {identity: next(item for item in pins if item["identity"] == identity) for identity in required}
    # FluidAudio is an independent research dependency, absent from the app.
    result["fluidaudio"] = {"identity": "fluidaudio", "kind": "remoteSourceControl",
        "location": "https://github.com/FluidInference/FluidAudio",
        "state": {"revision": "503b4bd1bbf7220882de39fe8ae6716aae4132da", "version": "0.17.7"}}
    return result


def build(output, *, entrypoint=None):
    """Let SwiftPM link comparison runtimes and C dependencies with the app's pins."""
    package = output / "package"
    sources = package / "Sources/Comparison"
    sources.mkdir(parents=True)
    for file in SOURCES:
        source = file.read_text()
        if entrypoint and file.name == "DictationBenchmark.swift":
            assert source.count("@main\n") == 1
            source = source.replace("@main\n", "", 1)
        (sources / file.name).write_text(source)
    if entrypoint:
        shutil.copyfile(entrypoint, sources / entrypoint.name)
    pins = runtime_pins()
    dependencies = []
    for identity in pins:
        pin = pins[identity]
        traits = ", traits: []" if identity == "fluidaudio" else ""
        dependencies.append('.package(url: "%s", revision: "%s"%s)' %
                            (pin["location"], pin["state"]["revision"], traits))
    (package / "Package.swift").write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "DictationComparison", platforms: [.macOS(.v15)], dependencies: [
    %s
], targets: [.executableTarget(name: "Comparison", dependencies: [
    .product(name: "FluidAudio", package: "FluidAudio"),
    .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
    .product(name: "MLX", package: "mlx-swift"),
    .product(name: "WhisperKit", package: "argmax-oss-swift")])])
''' % ",\n    ".join(dependencies))
    with (output / "build.log").open("w") as build_log:
        run(["swift", "build", "--package-path", package, "-c", "release", "-j", "4",
             "--build-system", "native"], log_file=build_log)
    binary_folder = subprocess.check_output(["swift", "build", "--package-path", str(package),
        "-c", "release", "--build-system", "native", "--show-bin-path"], text=True).strip()
    binary = output / "benchmark"
    shutil.copy2(Path(binary_folder) / "Comparison", binary)
    for bundle in Path(binary_folder).glob("*.bundle"):
        shutil.copytree(bundle, output / bundle.name)
    shutil.copyfile(package / "Package.resolved", output / "Package.resolved")
    identities = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"], text=True)
    match = re.search(r'"(Developer ID Application: [^"\n]+)"', identities)
    signer = match.group(1) if match else "-"
    signing = ["codesign", "--force", "--sign", signer]
    if match:
        signing += ["--options", "runtime", "--timestamp=none"]
    run([*signing, binary])
    return binary, signer


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="New directory for metrics and build logs")
    parser.add_argument("--cache", type=Path, default=CACHE)
    parser.add_argument("--models", nargs="+", choices=["small", "turbo", "largeV3"], default=["turbo"])
    parser.add_argument("--arms", nargs="+", default=["gpu", "ane", "all", "ane-gpu", "gpu-ane"],
                        choices=["gpu", "ane", "all", "ane-gpu", "gpu-ane", "ane-prewarm",
                                 "ane-no-fallback", "ane-vad"])
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--rounds", type=int, default=2, help="Alternate arm order between rounds")
    parser.add_argument("--stress", action="store_true", help="Use repeated paragraphs to exercise fallback behavior")
    args = parser.parse_args()
    if args.repetitions < 1 or args.rounds < 1:
        parser.error("Repetitions and rounds must be positive")
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    metadata = {"status": "running", "started": time.time(), "cache": str(args.cache),
                "microphoneUsed": False, "audioPlaybackUsed": False,
                "processNice": os.getpriority(os.PRIO_PROCESS, 0), "stressCorpus": args.stress,
                "hardware": subprocess.check_output(
                    ["sysctl", "-n", "machdep.cpu.brand_string", "hw.memsize"], text=True),
                "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                "sourceHashes": {str(file.relative_to(ROOT)): hashlib.sha256(file.read_bytes()).hexdigest()
                                 for file in SOURCES}}
    metadata_file = args.output / "metadata.json"
    metadata_file.write_text(json.dumps(metadata, indent=2))
    try:
        binary, metadata["signer"] = build(args.output)
        metadata["binarySha256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
        with tempfile.TemporaryDirectory(prefix="tlm-model-benchmark-") as temporary:
            manifest = corpus(Path(temporary), args.stress)
            cases = json.loads(manifest.read_text())
            metadata["corpus"] = [dict(id=case["id"], terms=case["terms"], expected=case["expected"],
                                      audioSha256=hashlib.sha256(Path(case["file"]).read_bytes()).hexdigest())
                                  for case in cases]
            for model in args.models:
                # Real engine verifies pinned assets before any direct SDK arm.
                modes = [("prepare", "prepare")]
                for round_index in range(args.rounds):
                    arms = args.arms if round_index % 2 == 0 else list(reversed(args.arms))
                    modes += [("round-%s-%s" % (round_index, arm), arm) for arm in arms]
                for label, arm in modes:
                    prefix = args.output / (model + "-" + label)
                    log.info("Starting %s %s", model, label)
                    with prefix.with_suffix(".log").open("w") as output_log:
                        run([binary, model, arm, args.cache, manifest, args.repetitions,
                             prefix.with_suffix(".json")], log_file=output_log)
                    if arm != "prepare":
                        report = json.loads(prefix.with_suffix(".json").read_text())
                        missing = validate(report, cases, args.repetitions)
                        log.info("Finished %s %s, rows with missing terms: %s", model, label, missing)
        metadata["status"] = "complete"
    except BaseException as error:
        metadata.update(status="failed", error=str(error))
        raise
    finally:
        metadata["finished"] = time.time()
        metadata_file.write_text(json.dumps(metadata, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    def interrupted(_number, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    main()
