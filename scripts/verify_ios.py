#!/usr/bin/env python3
"""Build, lint and run native tests on dedicated iPhone and iPad simulators."""

import argparse
import codecs
import json
import os
import plistlib
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
TEST_PLANS = ROOT / "JustMarkdown.xcodeproj/xcshareddata/xctestplans"


def ci_matrix(test_plan="CI"):
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
            for suite, count in [("unit", 1), ("ui", UI_SHARDS if test_plan == "Full" else 1)]
            for index in range(count)
            for family in SIMULATORS
        ]
    }


def required_ui_tests(test_plan):
    """The checked-in Xcode plan owns UI scope; unit targets always run in full."""
    plan = json.loads((TEST_PLANS / f"{test_plan}.xctestplan").read_text())
    targets = {item["target"]["name"]: item for item in plan["testTargets"]}
    if set(targets) != set(TEST_TARGETS.values()):
        raise ValueError("The offline test plan must contain both unit and UI targets")
    if any(item.get("enabled") is False or item.get("skippedTests") for item in targets.values()):
        raise ValueError("Disabled tests are not permitted in either test plan")
    if "selectedTests" in targets[TEST_TARGETS["unit"]]:
        raise ValueError("Unit and integration tests must always run in full")
    selected = targets[TEST_TARGETS["ui"]].get("selectedTests")
    if test_plan == "Full":
        if selected is not None:
            raise ValueError("The Full test plan must run every UI test")
        return None
    if not isinstance(selected, list) or not selected or len(set(selected)) != len(selected):
        raise ValueError("The CI plan must explicitly select its required UI tests")
    if any(
        not isinstance(item, str) or len(item.split("/")) != 2 or not item.endswith("()")
        for item in selected
    ):
        raise ValueError("Invalid UI test selection")
    return {f"{TEST_TARGETS['ui']}/{item.removesuffix('()')}" for item in selected}


def test_identifiers(enumeration, selected_ui=None):
    """Read compiled XCTest discovery; disabled or unknown tests are errors."""
    if enumeration.get("errors") != []:
        raise ValueError("Xcode test discovery reported errors")
    groups = enumeration.get("values")
    if not isinstance(groups, list) or not groups:
        raise ValueError("Xcode test discovery returned no test plans")
    identifiers = []
    for group in groups:
        disabled = group.get("disabledTests")
        if not isinstance(disabled, list):
            raise ValueError("Xcode test discovery returned invalid disabled tests")
        for item in disabled:
            identifier = item.get("identifier", "").removesuffix("()")
            if (
                selected_ui is None
                or not identifier.startswith(TEST_TARGETS["ui"] + "/")
                or identifier in selected_ui
            ):
                raise ValueError("A required test is disabled")
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
    if (
        selected_ui is not None
        and {item for item in identifiers if item.startswith(TEST_TARGETS["ui"] + "/")}
        != selected_ui
    ):
        raise ValueError("Compiled UI discovery does not match the selected test plan")
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


def test_run_specification(products, test_plan=None):
    specifications = list(products.glob("*.xctestrun"))
    if len(specifications) != 1:
        raise ValueError("Test products must contain exactly one .xctestrun specification")
    specification = specifications[0]
    if test_plan is not None:
        if not specification.name.startswith(f"JustMarkdown_{test_plan}_"):
            raise ValueError(f"Test products must be built with the {test_plan} test plan")
        metadata = plistlib.loads(specification.read_bytes())
        if metadata.get("TestPlan", {}).get("Name") != test_plan:
            raise ValueError("Compiled test plan does not match the requested plan")
        configurations = metadata.get("TestConfigurations")
        if not configurations or any(not item.get("IsEnabled") for item in configurations):
            raise ValueError("Compiled test configurations must all be enabled")
        selected_ui = required_ui_tests(test_plan)
        for configuration in configurations:
            if {target["BlueprintName"] for target in configuration["TestTargets"]} != set(
                TEST_TARGETS.values()
            ):
                raise ValueError("Compiled test products must contain both offline targets")
            for target in configuration["TestTargets"]:
                if target.get("SkipTestIdentifiers"):
                    raise ValueError("Unexpected disabled tests in compiled test products")
                if (
                    target["BlueprintName"] == TEST_TARGETS["unit"]
                    and "OnlyTestIdentifiers" in target
                ):
                    raise ValueError("Compiled unit and integration tests must run in full")
                if target["BlueprintName"] == TEST_TARGETS["ui"]:
                    actual = target.get("OnlyTestIdentifiers")
                    if selected_ui is None:
                        if actual is not None:
                            raise ValueError("Compiled Full plan must contain every UI test")
                    elif (
                        actual is None
                        or {f"{TEST_TARGETS['ui']}/{item.removesuffix('()')}" for item in actual}
                        != selected_ui
                    ):
                        raise ValueError("Compiled UI tests do not match the approved CI plan")
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
    parser.add_argument("--test-plan", choices=["Full", "CI"], default="Full")
    parser.add_argument("--shard-index", type=int, default=0, help="Zero-based shard index")
    parser.add_argument("--shard-count", type=int, default=1)
    parser.add_argument("--ci-matrix", action="store_true", help="Print the required CI job matrix")
    args = parser.parse_args()
    if args.ci_matrix:
        print("matrix=" + json.dumps(ci_matrix(args.test_plan), separators=(",", ":")))
        return 0
    selected_ui = required_ui_tests(args.test_plan)
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
                "-testPlan",
                args.test_plan,
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
    specification = test_run_specification(products, args.test_plan)
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
        identifiers = None
        expected_count = (
            len(selected_ui) if args.suite == "ui" and selected_ui is not None else None
        )
        if args.shard_count > 1:
            discovery = output / f"{family}-discovery.json"
            started = time.monotonic()
            print(f"{family}: discovering compiled tests for sharding", flush=True)
            run(
                [
                    "xcodebuild",
                    "test-without-building",
                    "-xctestrun",
                    str(specification),
                    "-destination",
                    destination,
                    "-parallel-testing-enabled",
                    "NO",
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
            identifiers = test_identifiers(json.loads(discovery.read_text()), selected_ui)
            print(f"{family}: test discovery took {time.monotonic() - started:.1f}s", flush=True)
            selected = select_tests(identifiers, args.suite, args.shard_index, args.shard_count)
            expected_count = len(selected)
        else:
            selected = (
                list(TEST_TARGETS.values()) if args.suite == "all" else [TEST_TARGETS[args.suite]]
            )
        plan = {
            "family": family,
            "suite": args.suite,
            "testPlan": args.test_plan,
            "shardIndex": args.shard_index,
            "shardCount": args.shard_count,
            "allTests": identifiers,
            "testSelectors": selected,
            "expectedCount": expected_count,
        }
        (output / f"{family}-plan.json").write_text(json.dumps(plan, indent=2) + "\n")
        print(
            f"Running {args.test_plan} plan, {args.suite} "
            f"shard {args.shard_index + 1}/{args.shard_count}: {', '.join(selected)}",
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
            and counts["totalTestCount"] > 0
            and (expected_count is None or counts["totalTestCount"] == expected_count)
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
                "testPlan": args.test_plan,
                "shardIndex": args.shard_index,
                "shardCount": args.shard_count,
                "testSelectors": selected,
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
