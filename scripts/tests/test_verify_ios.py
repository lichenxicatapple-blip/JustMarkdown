import collections
import plistlib
import tempfile
import unittest
from pathlib import Path

from scripts import verify_ios


class TestDiscoveryAndSharding(unittest.TestCase):
    def enumeration(self):
        return {
            "errors": [],
            "values": [
                {
                    "disabledTests": [],
                    "enabledTests": [
                        {"identifier": "JustMarkdownTests/EmptyBaseSuite"},
                        *[
                            {"identifier": f"JustMarkdownTests/Unit/testCase{index}()"}
                            for index in range(5)
                        ],
                        *[
                            {"identifier": f"JustMarkdownUITests/Reader/testCase{index}()"}
                            for index in range(11)
                        ],
                    ],
                }
            ],
        }

    def test_discovery_uses_compiled_methods_and_ignores_empty_base_suites(self):
        identifiers = verify_ios.test_identifiers(self.enumeration())
        self.assertEqual(len(identifiers), 16)
        self.assertTrue(all(len(item.split("/")) == 3 for item in identifiers))
        self.assertTrue(all(not item.endswith("()") for item in identifiers))

    def test_ci_matrix_executes_every_method_exactly_once_on_each_family(self):
        identifiers = verify_ios.test_identifiers(self.enumeration())
        jobs = verify_ios.ci_matrix("Full")["include"]
        self.assertEqual({job["family"] for job in jobs}, {"iPhone", "iPad"})
        for family in ["iPhone", "iPad"]:
            executed = [
                test
                for job in jobs
                if family == job["family"]
                for test in verify_ios.select_tests(
                    identifiers, job["suite"], job["shardIndex"], job["shardCount"]
                )
            ]
            self.assertEqual(collections.Counter(executed), collections.Counter(identifiers))

    def test_new_tests_are_included_without_updating_shard_lists(self):
        enumeration = self.enumeration()
        new_test = "JustMarkdownUITests/Reader/testNewBehavior"
        enumeration["values"][0]["enabledTests"].append({"identifier": new_test + "()"})
        identifiers = verify_ios.test_identifiers(enumeration)
        selected = [
            test
            for index in range(verify_ios.UI_SHARDS)
            for test in verify_ios.select_tests(identifiers, "ui", index, verify_ios.UI_SHARDS)
        ]
        self.assertEqual(selected.count(new_test), 1)

    def test_ci_and_full_plans_keep_unit_targets_complete_and_distinguish_ui_scope(self):
        self.assertIsNone(verify_ios.required_ui_tests("Full"))
        core = verify_ios.required_ui_tests("CI")
        self.assertGreater(len(core), 0)
        self.assertTrue(all(item.startswith("JustMarkdownUITests/") for item in core))
        jobs = verify_ios.ci_matrix("CI")["include"]
        self.assertEqual(
            collections.Counter((job["family"], job["suite"]) for job in jobs),
            collections.Counter(
                (family, suite) for family in ["iPhone", "iPad"] for suite in ["unit", "ui"]
            ),
        )
        self.assertTrue(all(job["shardIndex"] == 0 and job["shardCount"] == 1 for job in jobs))

    def test_core_discovery_only_allows_ui_cases_outside_approved_scope_to_be_disabled(self):
        enumeration = self.enumeration()
        group = enumeration["values"][0]
        omitted = group["enabledTests"][-3:]
        group["enabledTests"] = group["enabledTests"][:-3]
        group["disabledTests"] = omitted
        core = {
            item["identifier"].removesuffix("()")
            for item in group["enabledTests"]
            if item["identifier"].startswith("JustMarkdownUITests/")
        }
        self.assertEqual(len(verify_ios.test_identifiers(enumeration, core)), 13)
        with self.assertRaises(ValueError):
            verify_ios.test_identifiers(enumeration)
        for disabled in [group["enabledTests"][1], group["enabledTests"][-1]]:
            group["disabledTests"] = [disabled]
            with self.assertRaises(ValueError):
                verify_ios.test_identifiers(enumeration, core)
        group["disabledTests"] = omitted
        with self.assertRaises(ValueError):
            verify_ios.test_identifiers(
                enumeration, core | {omitted[0]["identifier"].removesuffix("()")}
            )

    def test_prebuilt_plan_rejects_profile_mismatch_or_hidden_test_filters(self):
        with tempfile.TemporaryDirectory() as directory:
            products = Path(directory)
            specification = products / "JustMarkdown_CI_iphonesimulator.xctestrun"
            unit = {"BlueprintName": "JustMarkdownTests"}
            ui = {
                "BlueprintName": "JustMarkdownUITests",
                "OnlyTestIdentifiers": [
                    item.split("/", 1)[1] + "()" for item in verify_ios.required_ui_tests("CI")
                ],
            }
            metadata = {
                "TestPlan": {"Name": "CI"},
                "TestConfigurations": [{"IsEnabled": True, "TestTargets": [unit, ui]}],
            }
            specification.write_bytes(plistlib.dumps(metadata))
            self.assertEqual(verify_ios.test_run_specification(products, "CI"), specification)
            with self.assertRaises(ValueError):
                verify_ios.test_run_specification(products, "Full")
            for item, key, value in [
                (unit, "OnlyTestIdentifiers", ["Unit/testOne()"]),
                (unit, "SkipTestIdentifiers", ["Unit/testOne()"]),
                (ui, "OnlyTestIdentifiers", ["Reader/testOther()"]),
                (metadata["TestPlan"], "Name", "Full"),
            ]:
                previous = item.get(key)
                item[key] = value
                specification.write_bytes(plistlib.dumps(metadata))
                with self.subTest(key=key), self.assertRaises(ValueError):
                    verify_ios.test_run_specification(products, "CI")
                if previous is None:
                    del item[key]
                else:
                    item[key] = previous

    def test_partition_is_independent_of_discovery_order(self):
        identifiers = verify_ios.test_identifiers(self.enumeration())
        for index in range(4):
            self.assertEqual(
                verify_ios.select_tests(identifiers, "ui", index, 4),
                verify_ios.select_tests(list(reversed(identifiers)), "ui", index, 4),
            )

    def test_disabled_tests_and_discovery_errors_cannot_pass(self):
        for field, value in [
            ("errors", ["discovery failed"]),
            ("disabledTests", [{"identifier": "JustMarkdownTests/Unit/testDisabled()"}]),
        ]:
            enumeration = self.enumeration()
            if field == "errors":
                enumeration[field] = value
            else:
                enumeration["values"][0][field] = value
            with self.assertRaises(ValueError):
                verify_ios.test_identifiers(enumeration)

    def test_malformed_duplicate_or_missing_targets_cannot_pass(self):
        cases = [{}, {"errors": [], "values": []}]
        for identifier in [
            None,
            "JustMarkdownUITests/Reader/unknown",
            "UnexpectedTarget/Reader/testUnexpected()",
            "JustMarkdownTests/Unit/testCase0()",
        ]:
            enumeration = self.enumeration()
            enumeration["values"][0]["enabledTests"].append({"identifier": identifier})
            cases.append(enumeration)
        enumeration = self.enumeration()
        enumeration["values"][0]["enabledTests"] = [
            {"identifier": "JustMarkdownTests/Unit/testOnlyUnit()"}
        ]
        cases.append(enumeration)
        for enumeration in cases:
            with self.subTest(enumeration=enumeration), self.assertRaises(ValueError):
                verify_ios.test_identifiers(enumeration)

    def test_invalid_or_empty_shards_cannot_pass(self):
        identifiers = verify_ios.test_identifiers(self.enumeration())
        for suite, index, count in [
            ("ui", -1, 4),
            ("ui", 4, 4),
            ("ui", 0, 0),
            ("ui", 11, 12),
            ("unknown", 0, 1),
        ]:
            with self.subTest(suite=suite, index=index, count=count), self.assertRaises(ValueError):
                verify_ios.select_tests(identifiers, suite, index, count)

    def test_prebuilt_products_require_one_run_specification(self):
        with tempfile.TemporaryDirectory() as directory:
            products = Path(directory)
            with self.assertRaises(ValueError):
                verify_ios.test_run_specification(products)
            first = products / "one.xctestrun"
            first.touch()
            self.assertEqual(verify_ios.test_run_specification(products), first)
            (products / "two.xctestrun").touch()
            with self.assertRaises(ValueError):
                verify_ios.test_run_specification(products)
