import copy
import json
import plistlib
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts import verify_ios


class FullTestExecution(unittest.TestCase):
    def setUp(self):
        output = patch("builtins.print")
        output.start()
        self.addCleanup(output.stop)

    def metadata(self):
        return {
            "TestPlan": {"Name": "Full"},
            "TestConfigurations": [
                {
                    "IsEnabled": True,
                    "TestTargets": [
                        {"BlueprintName": "JustMarkdownTests"},
                        {"BlueprintName": "JustMarkdownUITests"},
                    ],
                }
            ],
        }

    def test_shared_plan_enables_both_complete_targets(self):
        verify_ios.validate_test_plan()
        original = json.loads((verify_ios.TEST_PLANS / "Full.xctestplan").read_text())
        for changes in [
            {"enabled": False},
            {"selectedTests": []},
            {"selectedTests": ["Reader/testOne()"]},
            {"skippedTests": ["Reader/testOne()"]},
        ]:
            for index in range(2):
                plan = copy.deepcopy(original)
                plan["testTargets"][index].update(changes)
                with tempfile.TemporaryDirectory() as directory:
                    plans = Path(directory)
                    (plans / "Full.xctestplan").write_text(json.dumps(plan))
                    with (
                        self.subTest(index=index, changes=changes),
                        patch.object(verify_ios, "TEST_PLANS", plans),
                        self.assertRaises(ValueError),
                    ):
                        verify_ios.validate_test_plan()

    def test_prebuilt_products_cannot_filter_either_target(self):
        for index in range(2):
            for key, value in [
                ("OnlyTestIdentifiers", []),
                ("OnlyTestIdentifiers", ["Reader/testOne()"]),
                ("SkipTestIdentifiers", ["Reader/testOne()"]),
            ]:
                metadata = self.metadata()
                metadata["TestConfigurations"][0]["TestTargets"][index][key] = value
                with tempfile.TemporaryDirectory() as directory:
                    products = Path(directory)
                    (products / "JustMarkdown_Full.xctestrun").write_bytes(plistlib.dumps(metadata))
                    with self.subTest(index=index, key=key), self.assertRaises(ValueError):
                        verify_ios.test_run_specification(products)

    def test_prebuilt_products_require_full_enabled_configuration_and_both_targets(self):
        valid = self.metadata()
        variants = []
        other_plan = copy.deepcopy(valid)
        other_plan["TestPlan"]["Name"] = "CI"
        variants.append(other_plan)
        disabled = copy.deepcopy(valid)
        disabled["TestConfigurations"][0]["IsEnabled"] = False
        variants.append(disabled)
        missing_target = copy.deepcopy(valid)
        missing_target["TestConfigurations"][0]["TestTargets"].pop()
        variants.append(missing_target)
        empty = copy.deepcopy(valid)
        empty["TestConfigurations"] = []
        variants.append(empty)
        with tempfile.TemporaryDirectory() as directory:
            products = Path(directory)
            specification = products / "JustMarkdown_Full.xctestrun"
            specification.write_bytes(plistlib.dumps(valid))
            self.assertEqual(verify_ios.test_run_specification(products), specification)
            for metadata in variants:
                specification.write_bytes(plistlib.dumps(metadata))
                with self.subTest(metadata=metadata), self.assertRaises(ValueError):
                    verify_ios.test_run_specification(products)
            specification.unlink()
            with self.assertRaises(ValueError):
                verify_ios.test_run_specification(products)
            specification.write_bytes(plistlib.dumps(valid))
            (products / "second.xctestrun").write_bytes(plistlib.dumps(valid))
            with self.assertRaises(ValueError):
                verify_ios.test_run_specification(products)

    def summary(self, **updates):
        return {
            "totalTestCount": 126,
            "passedTests": 126,
            "failedTests": 0,
            "skippedTests": 0,
            "expectedFailures": 0,
            **updates,
        }

    def tree(self, names):
        return {
            "testNodes": [
                {
                    "nodeType": "Test Plan",
                    "children": [
                        {
                            "name": name,
                            "nodeType": "UI test bundle"
                            if name.endswith("UITests")
                            else "Unit test bundle",
                        }
                        for name in names
                    ],
                }
            ]
        }

    def test_summary_requires_actual_execution_of_every_requested_target(self):
        for names in [
            ["JustMarkdownTests", "JustMarkdownUITests"],
            ["JustMarkdownTests"],
            ["JustMarkdownUITests"],
        ]:
            outputs = [self.summary(), self.tree(names)]
            with (
                self.subTest(names=names),
                patch.object(
                    verify_ios,
                    "run",
                    side_effect=[
                        subprocess.CompletedProcess([], 0, json.dumps(d)) for d in outputs
                    ],
                ),
            ):
                result = verify_ios.test_summary(
                    Path("result.xcresult"), verify_ios.TEST_TARGETS.values()
                )
                self.assertEqual(result is not None, len(names) == 2)

    def test_invalid_or_expected_failure_results_cannot_be_accepted(self):
        for summary in [
            self.summary(expectedFailures=1),
            self.summary(passedTests="126"),
            self.summary(skippedTests=-1),
            self.summary(totalTestCount=True),
        ]:
            with (
                self.subTest(summary=summary),
                patch.object(
                    verify_ios,
                    "run",
                    return_value=subprocess.CompletedProcess([], 0, json.dumps(summary)),
                ),
            ):
                self.assertIsNone(
                    verify_ios.test_summary(
                        Path("result.xcresult"), verify_ios.TEST_TARGETS.values()
                    )
                )

    def test_failures_skips_empty_results_and_failed_xcode_exit_are_failures(self):
        for code, counts, expected in [
            (0, self.summary(), True),
            (1, self.summary(), False),
            (0, self.summary(totalTestCount=0, passedTests=0), False),
            (0, self.summary(passedTests=125, failedTests=1), False),
            (0, self.summary(passedTests=125, skippedTests=1), False),
            (0, None, False),
        ]:
            with (
                self.subTest(code=code, counts=counts),
                tempfile.TemporaryDirectory() as directory,
                patch.object(verify_ios, "run"),
                patch.object(verify_ios, "run_tests", return_value=code) as run_tests,
                patch.object(verify_ios, "test_summary", return_value=counts),
                patch.object(verify_ios, "failure_details"),
            ):
                result = verify_ios.verify_family(
                    "iPhone",
                    runtime={"name": "iOS 26.5", "identifier": "runtime"},
                    devices=[{"name": "JustMarkdown iPhone", "udid": "phone", "state": "Booted"}],
                    specification=Path("full.xctestrun"),
                    output=Path(directory),
                    suite="all",
                    prefix="JustMarkdown",
                    cancel=threading.Event(),
                )
                self.assertEqual(result["passed"], expected)
                command = run_tests.call_args.args[0]
                self.assertEqual(
                    [arg for arg in command if arg.startswith("-only-testing:")],
                    ["-only-testing:JustMarkdownTests", "-only-testing:JustMarkdownUITests"],
                )
                self.assertFalse(any(arg.startswith("-skip-testing:") for arg in command))

    def test_families_run_concurrently_and_keep_both_results_when_one_fails(self):
        barrier = threading.Barrier(2)

        def execute(family, **options):
            barrier.wait(timeout=3)
            return {"family": family, "passed": family == "iPad"}

        with patch.object(verify_ios, "verify_family", side_effect=execute) as execute_mock:
            results = verify_ios.verify_families(["iPhone", "iPad"])
        self.assertEqual(execute_mock.call_count, 2)
        self.assertEqual(
            results, [{"family": "iPhone", "passed": False}, {"family": "iPad", "passed": True}]
        )

    def test_infrastructure_failure_does_not_omit_the_other_family(self):
        def execute(family, **options):
            if family == "iPhone":
                raise OSError("Simulator unavailable")
            return {"family": family, "passed": True}

        with patch.object(verify_ios, "verify_family", side_effect=execute):
            results = verify_ios.verify_families(["iPhone", "iPad"])
        self.assertEqual(len(results), 2)
        self.assertFalse(results[0]["passed"])
        self.assertTrue(results[1]["passed"])
        self.assertIn("Simulator unavailable", results[0]["error"])

    def test_cancellation_terminates_running_xcode_process(self):
        cancel = threading.Event()
        timer = threading.Timer(0.2, cancel.set)
        with tempfile.TemporaryDirectory() as directory:
            timer.start()
            try:
                code = verify_ios.run_tests(
                    [sys.executable, "-c", "import time; time.sleep(30)"],
                    Path(directory) / "cancel.log",
                    cancel=cancel,
                )
            finally:
                timer.cancel()
        self.assertEqual(code, 130)
