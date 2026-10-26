import collections
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
        jobs = verify_ios.ci_matrix()["include"]
        self.assertEqual({family for job in jobs for family in job["families"]}, {"iPhone", "iPad"})
        for family in ["iPhone", "iPad"]:
            executed = [
                test
                for job in jobs
                if family in job["families"]
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
