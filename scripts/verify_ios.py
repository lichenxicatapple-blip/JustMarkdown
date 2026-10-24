#!/usr/bin/env python3
"""Build, lint and run native tests on dedicated iPhone and iPad simulators."""

import argparse
import json
import subprocess
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(arguments, **options):
    return subprocess.run(arguments, cwd=ROOT, check=True, **options)


def simulator_data(kind):
    return json.loads(
        run(
            ["xcrun", "simctl", "list", kind, "available", "-j"],
            capture_output=True,
            text=True,
        ).stdout
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--family", choices=["iPhone", "iPad"], help="Verify one simulator family")
    parser.add_argument(
        "--output", type=Path, help="Directory for disposable build and test artifacts"
    )
    args = parser.parse_args()
    if not (ROOT / "JustMarkdown.xcodeproj/project.pbxproj").is_file():
        raise SystemExit("Missing JustMarkdown.xcodeproj. Use a complete project checkout.")
    run([sys.executable, "scripts/build_native_web.py"])
    for script in ["reader.js", "agent.js", "source-history.js", "localization.js"]:
        run(["node", "--check", f"JustMarkdown/Resources/Web/{script}"])
    run(
        [
            "xcrun",
            "swift-format",
            "lint",
            "--strict",
            "--recursive",
            "--configuration",
            ".swift-format",
            "JustMarkdown",
            "JustMarkdownTests",
            "JustMarkdownUITests",
        ]
    )
    runtimes = [
        item
        for item in simulator_data("runtimes")["runtimes"]
        if item["isAvailable"]
        and item.get("platform") == "iOS"
        and int(item["version"].split(".")[0]) >= 26
    ]
    if not runtimes:
        raise SystemExit(
            "Install an iOS 26+ simulator runtime in Xcode before running verification."
        )
    runtime = max(runtimes, key=lambda item: tuple(map(int, item["version"].split("."))))
    devices = simulator_data("devices")["devices"].get(runtime["identifier"], [])
    output = (
        args.output
        or ROOT / "output/native" / datetime.now().strftime("validation-%Y%m%d-%H%M%S-%f")
    ).resolve()
    output.mkdir(parents=True, exist_ok=False)
    results = []
    for family, device_type in [
        ("iPhone", "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"),
        ("iPad", "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB"),
    ]:
        if args.family and args.family != family:
            continue
        name = f"JustMarkdown {family}"
        device = next((item for item in devices if item["name"] == name), None)
        if device is None:
            identifier = run(
                ["xcrun", "simctl", "create", name, device_type, runtime["identifier"]],
                capture_output=True,
                text=True,
            ).stdout.strip()
            device = {"udid": identifier, "state": "Shutdown"}
        identifier = device["udid"]
        if device["state"] != "Booted":
            run(["xcrun", "simctl", "boot", identifier])
        run(["xcrun", "simctl", "bootstatus", identifier, "-b"])
        bundle = output / f"{family}.xcresult"
        log = output / f"{family}.log"
        print(f"Testing {family} on {runtime['name']}. Results: {bundle}", flush=True)
        arguments = [
            "xcodebuild",
            "-project",
            "JustMarkdown.xcodeproj",
            "-scheme",
            "JustMarkdown",
            "-destination",
            f"platform=iOS Simulator,id={identifier}",
            "-derivedDataPath",
            str(output / "DerivedData"),
            "-resultBundlePath",
            str(bundle),
            "-parallel-testing-enabled",
            "NO",
            "test",
        ]
        with log.open("w") as stream:
            process = subprocess.run(arguments, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
        results.append(
            {
                "family": family,
                "device": identifier,
                "runtime": runtime["name"],
                "passed": process.returncode == 0,
                "resultBundle": str(bundle),
                "log": str(log),
            }
        )
        print(f"{family}: {'passed' if process.returncode == 0 else 'failed'}", flush=True)
        if process.returncode != 0:
            print(
                "\n".join(log.read_text(errors="replace").splitlines()[-80:]),
                flush=True,
            )
    (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print(output, flush=True)
    return 0 if all(item["passed"] for item in results) else 1


if __name__ == "__main__":
    sys.exit(main())
