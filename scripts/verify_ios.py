#!/usr/bin/env python3
"""Build, lint and run native tests on dedicated iPhone and iPad simulators."""

import argparse
import codecs
import concurrent.futures
import json
import os
import plistlib
import selectors
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SIMULATORS = {
    "iPhone": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
    "iPad": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB",
}
TEST_TARGETS = {"unit": "JustMarkdownTests", "ui": "JustMarkdownUITests"}
TEST_PLANS = ROOT / "JustMarkdown.xcodeproj/xcshareddata/xctestplans"


def validate_test_plan():
    """The shared plan must enable every test in both offline targets."""
    plan = json.loads((TEST_PLANS / "Full.xctestplan").read_text())
    targets = plan["testTargets"]
    if len(targets) != len(TEST_TARGETS) or {item["target"]["name"] for item in targets} != set(
        TEST_TARGETS.values()
    ):
        raise ValueError("The offline test plan must contain both unit and UI targets")
    for target in targets:
        if (
            target.get("enabled") is False
            or target.get("skippedTests")
            or "selectedTests" in target
        ):
            raise ValueError("The offline test plan must run every test")


def test_run_specification(products):
    """Reject prebuilt products that silently narrow the full test plan."""
    specifications = list(products.glob("*.xctestrun"))
    if len(specifications) != 1:
        raise ValueError("Test products must contain exactly one .xctestrun specification")
    specification = specifications[0]
    metadata = plistlib.loads(specification.read_bytes())
    if metadata.get("TestPlan", {}).get("Name") != "Full":
        raise ValueError("Test products must be built with the Full test plan")
    configurations = metadata.get("TestConfigurations")
    if not configurations or any(not item.get("IsEnabled") for item in configurations):
        raise ValueError("Compiled test configurations must all be enabled")
    for configuration in configurations:
        targets = configuration["TestTargets"]
        if len(targets) != len(TEST_TARGETS) or {
            target["BlueprintName"] for target in targets
        } != set(TEST_TARGETS.values()):
            raise ValueError("Compiled test products must contain both offline targets")
        if any(
            target.get("SkipTestIdentifiers") or "OnlyTestIdentifiers" in target
            for target in targets
        ):
            raise ValueError("Compiled test products must run every test")
    return specification


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


def run_tests(arguments, log, inactivity_timeout=600, cancel=None, label=None):
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
        last_output = time.monotonic()

        def display(value):
            if label:
                value = "".join(f"[{label}] {line}" for line in value.splitlines(keepends=True))
            print(value, end="", flush=True)

        try:
            while True:
                if cancel is not None and cancel.is_set():
                    return 130
                if time.monotonic() - last_output >= inactivity_timeout:
                    message = (
                        f"\nNo Xcode output for {inactivity_timeout} seconds; "
                        "interrupting the test process and retaining diagnostics.\n"
                    )
                    stream.write(message.encode())
                    stream.flush()
                    print(message, end="", flush=True)
                    return 1
                if not selector.select(timeout=min(1, inactivity_timeout)):
                    continue
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk:
                    break
                last_output = time.monotonic()
                stream.write(chunk)
                stream.flush()
                display(decoder.decode(chunk))
            display(decoder.decode(b"", final=True))
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
                    display(decoder.decode(remaining, final=True))


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


def test_summary(bundle, expected_targets):
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
        if not all(type(value) is int and value >= 0 for value in counts.values()):
            raise ValueError("Invalid test counts")
        if summary.get("expectedFailures", 0):
            raise ValueError("Expected failures require explicit maintainer approval")
        tree = json.loads(
            run(
                ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle)],
                capture_output=True,
                text=True,
            ).stdout
        )
        bundles = [
            node
            for root in tree["testNodes"]
            for node in root.get("children", [])
            if node.get("nodeType") in {"Unit test bundle", "UI test bundle"}
        ]
        if {node["name"] for node in bundles} != set(expected_targets):
            raise ValueError("XCTest did not execute every requested target")
    except (OSError, subprocess.CalledProcessError, ValueError, KeyError) as error:
        print(f"Unable to verify XCTest results: {type(error).__name__}", flush=True)
        return None
    if counts["skippedTests"]:
        print(
            f"Verification incomplete: {counts['skippedTests']} test(s) were skipped.", flush=True
        )
    return counts


def verify_family(family, runtime, devices, specification, output, suite, prefix, cancel):
    """Execute a complete target selection on one dedicated simulator."""
    started = time.monotonic()
    name = f"{prefix} {family}"
    device = next((item for item in devices if item["name"] == name), None)
    if device is None:
        identifier = run(
            ["xcrun", "simctl", "create", name, SIMULATORS[family], runtime["identifier"]],
            capture_output=True,
            text=True,
        ).stdout.strip()
        device = {"udid": identifier, "state": "Shutdown"}
    identifier = device["udid"]
    print(f"{family}: preparing simulator {identifier} on {runtime['name']}", flush=True)
    if device["state"] != "Booted":
        run(["xcrun", "simctl", "boot", identifier])
    run(["xcrun", "simctl", "bootstatus", identifier, "-b"])
    preparation_seconds = time.monotonic() - started
    print(f"{family}: simulator ready after {preparation_seconds:.1f}s", flush=True)
    bundle = output / f"{family}.xcresult"
    log = output / f"{family}.log"
    selected = list(TEST_TARGETS.values()) if suite == "all" else [TEST_TARGETS[suite]]
    print(f"{family}: running Full plan: {', '.join(selected)}", flush=True)
    started = time.monotonic()
    code = run_tests(
        [
            "xcodebuild",
            "test-without-building",
            "-xctestrun",
            str(specification),
            "-destination",
            f"platform=iOS Simulator,id={identifier}",
            "-resultBundlePath",
            str(bundle),
            "-parallel-testing-enabled",
            "NO",
            "-test-timeouts-enabled",
            "YES",
            *[f"-only-testing:{target}" for target in selected],
        ],
        log,
        cancel=cancel,
        label=family,
    )
    execution_seconds = time.monotonic() - started
    counts = test_summary(bundle, selected)
    passed = (
        code == 0
        and counts is not None
        and counts["totalTestCount"] > 0
        and counts["passedTests"] == counts["totalTestCount"]
        and counts["failedTests"] == 0
        and counts["skippedTests"] == 0
    )
    print(
        f"{family}: {'passed' if passed else 'failed'} after {execution_seconds:.1f}s", flush=True
    )
    if not passed:
        failure_details(bundle, identifier, output)
    return {
        "family": family,
        "device": identifier,
        "runtime": runtime["name"],
        "passed": passed,
        "testCounts": counts,
        "suite": suite,
        "testPlan": "Full",
        "preparationSeconds": round(preparation_seconds, 1),
        "executionSeconds": round(execution_seconds, 1),
        "testSelectors": selected,
        "resultBundle": str(bundle),
        "log": str(log),
    }


def verify_families(families, **options):
    """Run each family once; a failure must not suppress the other family's result."""
    results = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(families)) as executor:
        futures = {executor.submit(verify_family, family, **options): family for family in families}
        for future in concurrent.futures.as_completed(futures):
            family = futures[future]
            try:
                results[family] = future.result()
            except (OSError, subprocess.SubprocessError, ValueError, KeyError) as error:
                print(f"{family}: verification failed: {error}", flush=True)
                results[family] = {"family": family, "passed": False, "error": str(error)}
    return [results[family] for family in families]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--family", choices=SIMULATORS, help="Verify one simulator family")
    parser.add_argument(
        "--output", type=Path, help="Directory for disposable build and test artifacts"
    )
    parser.add_argument("--test-products", type=Path, help="Use prebuilt simulator test products")
    parser.add_argument("--suite", choices=["all", *TEST_TARGETS], default="all")
    parser.add_argument(
        "--simulator-prefix", default="JustMarkdown", help="Name prefix for dedicated simulators"
    )
    args = parser.parse_args()
    if not args.simulator_prefix.strip():
        parser.error("simulator-prefix must not be empty")
    validate_test_plan()
    if not (ROOT / "JustMarkdown.xcodeproj/project.pbxproj").is_file():
        raise SystemExit("Missing JustMarkdown.xcodeproj. Use a complete project checkout.")
    cancel = threading.Event()
    previous_handlers = {
        sig: signal.signal(sig, lambda _signal, _frame: cancel.set())
        for sig in (signal.SIGINT, signal.SIGTERM)
    }
    try:
        return verify(args, cancel)
    finally:
        for sig, handler in previous_handlers.items():
            signal.signal(sig, handler)


def verify(args, cancel):
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
        raise SystemExit("Install an iOS 26+ simulator runtime in Xcode before verification.")
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
                "-testPlan",
                "Full",
                "-destination",
                "generic/platform=iOS Simulator",
                "-derivedDataPath",
                str(output / "DerivedData"),
                "build-for-testing",
            ],
            output / "build.log",
            cancel=cancel,
        )
        if code:
            return code
    specification = test_run_specification(products)
    families = [args.family] if args.family else list(SIMULATORS)
    results = verify_families(
        families,
        runtime=runtime,
        devices=devices,
        specification=specification,
        output=output,
        suite=args.suite,
        prefix=args.simulator_prefix,
        cancel=cancel,
    )
    (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print(output, flush=True)
    return 0 if all(item["passed"] for item in results) else 1


if __name__ == "__main__":
    sys.exit(main())
