#!/usr/bin/env python3
"""Build, lint and run native tests on dedicated iPhone and iPad simulators."""

import argparse
import codecs
import json
import os
import selectors
import signal
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SIMULATORS = {
    "iPhone": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
    "iPad": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB",
}
TEST_TARGETS = {"unit": "JustMarkdownTests", "ui": "JustMarkdownUITests"}
UI_SHARDS = 4


def ci_matrix():
    """Keep the complete set of required simulator jobs in one place."""
    return {
        "include": [
            {
                "family": family,
                "suite": suite,
                "shardIndex": index,
                "shardCount": count,
                "label": f"{family} {suite} {index + 1} of {count}",
            }
            for suite, count in [("unit", 1), ("ui", UI_SHARDS)]
            for index in range(count)
            for family in SIMULATORS
        ]
    }


def test_identifiers(enumeration):
    """Read compiled XCTest discovery; disabled or unknown tests are errors."""
    if enumeration.get("errors") != []:
        raise ValueError("Xcode test discovery reported errors")
    groups = enumeration.get("values")
    if not isinstance(groups, list) or not groups:
        raise ValueError("Xcode test discovery returned no test plans")
    identifiers = []
    for group in groups:
        if group.get("disabledTests") != []:
            raise ValueError("Disabled tests are not permitted")
        enabled = group.get("enabledTests")
        if not isinstance(enabled, list):
            raise ValueError("Xcode test discovery returned invalid tests")
        for item in enabled:
            identifier = item.get("identifier")
            if not isinstance(identifier, str):
                raise ValueError("Xcode test discovery returned an invalid identifier")
            parts = identifier.split("/")
            # XCTest also lists empty base suites, which contain no test methods.
            if len(parts) == 2 and all(parts):
                continue
            if len(parts) != 3 or not all(parts) or not parts[-1].endswith("()"):
                raise ValueError(f"Unsupported test identifier: {identifier}")
            identifiers.append(identifier.removesuffix("()"))
    if not identifiers or len(identifiers) != len(set(identifiers)):
        raise ValueError("Xcode test discovery returned empty or duplicate tests")
    if {item.split("/")[0] for item in identifiers} != set(TEST_TARGETS.values()):
        raise ValueError("The offline test plan must contain both unit and UI targets")
    return sorted(identifiers)


def select_tests(identifiers, suite, index, count):
    """Partition a complete discovered suite with no overlap or omissions."""
    if count < 1 or not 0 <= index < count:
        raise ValueError("Invalid shard index or count")
    if suite != "all" and suite not in TEST_TARGETS:
        raise ValueError("Unknown test suite")
    tests = sorted(
        item for item in identifiers if suite == "all" or item.split("/")[0] == TEST_TARGETS[suite]
    )
    selected = tests[index::count]
    if not selected:
        raise ValueError("The selected test shard is empty")
    return selected


def test_run_specification(products):
    specifications = list(products.glob("*.xctestrun"))
    if len(specifications) != 1:
        raise ValueError("Test products must contain exactly one .xctestrun specification")
    return specifications[0]


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


def run_tests(arguments, log, inactivity_timeout=600):
    """Stream Xcode output while preserving a complete log and detecting silence."""
    decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
    with (
        log.open("wb") as stream,
        subprocess.Popen(
            arguments,
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        ) as process,
        selectors.DefaultSelector() as selector,
    ):
        selector.register(process.stdout, selectors.EVENT_READ)
        completed = False
        try:
            while True:
                if not selector.select(timeout=inactivity_timeout):
                    message = (
                        f"\nNo Xcode output for {inactivity_timeout} seconds; "
                        "interrupting the test process and retaining diagnostics.\n"
                    )
                    stream.write(message.encode())
                    stream.flush()
                    print(message, end="", flush=True)
                    return 1
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk:
                    break
                stream.write(chunk)
                stream.flush()
                print(decoder.decode(chunk), end="", flush=True)
            print(decoder.decode(b"", final=True), end="", flush=True)
            try:
                code = process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                print("Xcode closed its output without exiting; interrupting tests.", flush=True)
                return 1
            completed = True
            return code
        finally:
            if not completed:
                # SIGINT lets Xcode finish its result bundle before a forced stop.
                try:
                    os.killpg(process.pid, signal.SIGINT)
                except ProcessLookupError:
                    pass
                try:
                    remaining, _ = process.communicate(timeout=30)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    remaining, _ = process.communicate()
                if remaining:
                    stream.write(remaining)
                    stream.flush()
                    print(decoder.decode(remaining, final=True), end="", flush=True)


def failure_details(bundle, device, output):
    summary = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle)],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if summary.returncode == 0:
        for failure in json.loads(summary.stdout).get("testFailures", []):
            print(f"{failure['testName']}: {failure['failureText']}", flush=True)
    # Collect the app's document error domains and codes without document contents or credentials.
    diagnostics = output / f"{device}-documents.log"
    try:
        with diagnostics.open("w") as stream:
            subprocess.run(
                [
                    "xcrun",
                    "simctl",
                    "spawn",
                    device,
                    "log",
                    "show",
                    "--style",
                    "compact",
                    "--last",
                    "45m",
                    "--predicate",
                    'subsystem == "dev.catli.JustMarkdown" AND category == "Documents"',
                ],
                stdout=stream,
                stderr=subprocess.STDOUT,
                timeout=30,
                check=False,
            )
        print(diagnostics.read_text(errors="replace"), flush=True)
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"Unable to collect document diagnostics: {type(error).__name__}", flush=True)


def test_summary(bundle):
    """Require a complete offline XCTest result; skipped cases fail verification."""
    try:
        summary = json.loads(
            run(
                ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle)],
                capture_output=True,
                text=True,
            ).stdout
        )
        counts = {
            key: summary[key]
            for key in ["totalTestCount", "passedTests", "failedTests", "skippedTests"]
        }
        if not all(isinstance(value, int) and value >= 0 for value in counts.values()):
            raise ValueError("Invalid test counts")
    except (OSError, subprocess.CalledProcessError, ValueError, KeyError) as error:
        print(f"Unable to verify XCTest results: {type(error).__name__}", flush=True)
        return None
    if counts["skippedTests"]:
        print(
            f"Verification incomplete: {counts['skippedTests']} test(s) were skipped.", flush=True
        )
    return counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--family", choices=SIMULATORS, help="Verify one simulator family")
    parser.add_argument(
        "--output", type=Path, help="Directory for disposable build and test artifacts"
    )
    parser.add_argument("--test-products", type=Path, help="Use prebuilt simulator test products")
    parser.add_argument("--suite", choices=["all", *TEST_TARGETS], default="all")
    parser.add_argument("--shard-index", type=int, default=0, help="Zero-based shard index")
    parser.add_argument("--shard-count", type=int, default=1)
    parser.add_argument("--ci-matrix", action="store_true", help="Print the required CI job matrix")
    args = parser.parse_args()
    if args.ci_matrix:
        print("matrix=" + json.dumps(ci_matrix(), separators=(",", ":")))
        return 0
    if args.shard_count < 1 or not 0 <= args.shard_index < args.shard_count:
        parser.error("shard-index must be in [0, shard-count)")
    if not (ROOT / "JustMarkdown.xcodeproj/project.pbxproj").is_file():
        raise SystemExit("Missing JustMarkdown.xcodeproj. Use a complete project checkout.")
    if args.test_products is None:
        run([sys.executable, "scripts/build_native_web.py"])
        for script in ["reader.js", "agent.js", "localization.js"]:
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
                "JustMarkdownLiveTests",
                "scripts",
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
    products = (
        args.test_products.resolve()
        if args.test_products
        else output / "DerivedData/Build/Products"
    )
    if args.test_products is None:
        code = run_tests(
            [
                "xcodebuild",
                "-project",
                "JustMarkdown.xcodeproj",
                "-scheme",
                "JustMarkdown",
                "-destination",
                "generic/platform=iOS Simulator",
                "-derivedDataPath",
                str(output / "DerivedData"),
                "build-for-testing",
            ],
            output / "build.log",
        )
        if code:
            return code
    specification = test_run_specification(products)
    results = []
    for family, device_type in SIMULATORS.items():
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
        started = time.monotonic()
        print(f"{family}: preparing simulator {identifier} on {runtime['name']}", flush=True)
        if device["state"] != "Booted":
            run(["xcrun", "simctl", "boot", identifier])
        run(["xcrun", "simctl", "bootstatus", identifier, "-b"])
        print(f"{family}: simulator ready after {time.monotonic() - started:.1f}s", flush=True)
        bundle = output / f"{family}.xcresult"
        log = output / f"{family}.log"
        destination = f"platform=iOS Simulator,id={identifier}"
        discovery = output / f"{family}-discovery.json"
        started = time.monotonic()
        print(f"{family}: discovering compiled tests", flush=True)
        run(
            [
                "xcodebuild",
                "test-without-building",
                "-xctestrun",
                str(specification),
                "-destination",
                destination,
                "-enumerate-tests",
                "-test-enumeration-style",
                "flat",
                "-test-enumeration-format",
                "json",
                "-test-enumeration-output-path",
                str(discovery),
            ],
            stdout=subprocess.PIPE,
        )
        identifiers = test_identifiers(json.loads(discovery.read_text()))
        print(f"{family}: test discovery took {time.monotonic() - started:.1f}s", flush=True)
        selected = select_tests(identifiers, args.suite, args.shard_index, args.shard_count)
        plan = {
            "family": family,
            "suite": args.suite,
            "shardIndex": args.shard_index,
            "shardCount": args.shard_count,
            "allTests": identifiers,
            "selectedTests": selected,
        }
        (output / f"{family}-plan.json").write_text(json.dumps(plan, indent=2) + "\n")
        print(
            f"Running {len(selected)} discovered tests: {args.suite} "
            f"shard {args.shard_index + 1}/{args.shard_count}",
            flush=True,
        )
        print(f"Testing {family} on {runtime['name']}. Results: {bundle}", flush=True)
        arguments = [
            "xcodebuild",
            "test-without-building",
            "-xctestrun",
            str(specification),
            "-destination",
            destination,
            "-resultBundlePath",
            str(bundle),
            "-parallel-testing-enabled",
            "NO",
            "-test-timeouts-enabled",
            "YES",
        ] + [f"-only-testing:{test}" for test in selected]
        code = run_tests(arguments, log)
        counts = test_summary(bundle)
        passed = (
            code == 0
            and counts is not None
            and counts["totalTestCount"] == len(selected)
            and counts["passedTests"] == counts["totalTestCount"]
            and counts["failedTests"] == 0
            and counts["skippedTests"] == 0
        )
        results.append(
            {
                "family": family,
                "device": identifier,
                "runtime": runtime["name"],
                "passed": passed,
                "testCounts": counts,
                "suite": args.suite,
                "shardIndex": args.shard_index,
                "shardCount": args.shard_count,
                "selectedTests": selected,
                "resultBundle": str(bundle),
                "log": str(log),
            }
        )
        print(f"{family}: {'passed' if passed else 'failed'}", flush=True)
        if not passed:
            failure_details(bundle, identifier, output)
            print(
                "\n".join(log.read_text(errors="replace").splitlines()[-80:]),
                flush=True,
            )
    (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print(output, flush=True)
    return 0 if all(item["passed"] for item in results) else 1


if __name__ == "__main__":
    sys.exit(main())
