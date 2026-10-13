import json
import unittest
from pathlib import Path
from uuid import UUID

ROOT = Path(__file__).resolve().parents[1]
PREFIX = "a6c90100-"
PAGE = "a6c90100-487a-4e37-9b5a-21bbc3b67a01"


class TagDashboardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dashboard = json.loads((ROOT / "finops-hub-dashboard.json").read_text(encoding="utf-8"))
        cls.queries = {item["id"]: item for item in cls.dashboard["queries"]}
        cls.parameters = {
            item.get("variableName", item.get("beginVariableName")): item
            for item in cls.dashboard["parameters"]
        }
        cls.bases = {item["variableName"]: item["queryId"] for item in cls.dashboard["baseQueries"]}
        cls.setup = (ROOT / "fabric" / "finops-hub-subscription-tags.kql").read_text(encoding="utf-8")

    def test_ids_and_query_references_are_unique_and_valid(self):
        for name in ("pages", "tiles", "parameters", "baseQueries", "queries", "dataSources"):
            ids = [item["id"] for item in self.dashboard[name]]
            self.assertEqual(len(ids), len(set(ids)), name)
            for value in ids:
                UUID(value)
        for item in self.dashboard["tiles"]:
            self.assertIn(item["pageId"], {page["id"] for page in self.dashboard["pages"]})
            if "queryRef" in item:
                self.assertIn(item["queryRef"]["queryId"], self.queries)
        for item in self.dashboard["baseQueries"]:
            self.assertIn(item["queryId"], self.queries)
        for item in self.dashboard["parameters"]:
            source = item.get("dataSource", {})
            if source.get("kind") == "query":
                self.assertIn(source["queryRef"]["queryId"], self.queries)

    def test_dependencies_have_no_cycles_or_unknown_variables(self):
        variables = set(self.bases)
        for item in self.dashboard["parameters"]:
            variables.update(item[key] for key in ("variableName", "beginVariableName", "endVariableName") if key in item)
        for query in self.queries.values():
            self.assertTrue(set(query["usedVariables"]) <= variables)
        visited = set()

        def visit(name, stack):
            self.assertNotIn(name, stack)
            if name in visited or name not in self.bases:
                return
            for variable in self.queries[self.bases[name]]["usedVariables"]:
                visit(variable, stack | {name})
            visited.add(name)

        for name in self.bases:
            visit(name, set())

    def test_filters_are_scoped_to_the_new_page(self):
        new_parameters = [item for item in self.dashboard["parameters"] if item["id"].startswith(PREFIX)]
        self.assertEqual(len(new_parameters), 5)
        for item in new_parameters:
            self.assertEqual(item["showOnPages"], {"kind": "selection", "pageIds": [PAGE]})
        for name in ("selectedTagSubscriptions", "selectedTagNames", "selectedTagPairs"):
            item = self.parameters[name]
            self.assertEqual(item["selectionType"], "array")
            self.assertTrue(item["allIsNull"])
            self.assertTrue(item["dataSource"]["autoReset"])
            self.assertTrue(item["includeAllOption"])
            self.assertEqual(item["defaultValue"], {"kind": "all"})
        self.assertIn("multi-select", self.parameters["selectedTagNames"]["displayName"])
        choices = self.parameters["selectedTagSource"]["dataSource"]["values"]
        self.assertEqual({item["value"] for item in choices}, {"Both", "Subscription", "Resource/cost"})

    def test_pair_keys_do_not_cross_match_names_sources_or_untagged(self):
        query = self.queries[self.bases["TagCostRows"]]["text"]
        self.assertIn("pack_array(TagSource, HasTag, TagName, TagValue)", query)
        self.assertIn("pack_array(HasTag, TagName)", query)
        query = self.queries[self.bases["FilteredTagCostRows"]]["text"]
        self.assertIn("TagPairKey in (selectedTagPairs)", query)
        self.assertIn("TagNameKey in (selectedTagNames)", query)
        self.assertIn("isnull(selectedTagPairs)", query)
        self.assertNotIn("array_length(selectedTagPairs) == 0", query)

    def test_totals_use_original_costs_not_expanded_tag_rows(self):
        query = self.queries["a6c90100-487a-4e37-9b5a-21bbc3b67a28"]["text"]
        self.assertIn("summarize SubscriptionName = take_any(SubscriptionName) by SubscriptionId", query)
        self.assertIn("TagPeriodCosts\n    | summarize", query)
        self.assertIn("by SubscriptionId, BillingCurrency", query)
        self.assertNotIn("FilteredTagCostRows\n| summarize BilledCost", query)

    def test_bounds_currency_no_cost_and_untagged_are_explicit(self):
        self.assertIn("ChargePeriodStart >= startDate and ChargePeriodStart < endDate", self.setup)
        self.assertIn("BillingCurrency == currency", self.setup)
        self.assertIn("by SubscriptionId, BillingCurrency", self.setup)
        self.assertIn('dynamic([""])', self.setup)
        self.assertIn("coalesce(array_length(TagKeys), 0)", self.setup)
        self.assertIn("join kind=leftouter", self.setup)
        self.assertIn("No cost records in selected period/currency", self.setup)
        self.assertIn("arg_max(SnapshotAt, *) by SubscriptionId", self.setup)

    def test_page_tiles_do_not_overlap_and_explain_tag_overlap(self):
        tiles = [item for item in self.dashboard["tiles"] if item["pageId"] == PAGE]
        self.assertEqual(len(tiles), 5)
        for index, first in enumerate(tiles):
            a = first["layout"]
            for second in tiles[index + 1:]:
                b = second["layout"]
                overlap = a["x"] < b["x"] + b["width"] and b["x"] < a["x"] + a["width"]
                overlap &= a["y"] < b["y"] + b["height"] and b["y"] < a["y"] + a["height"]
                self.assertFalse(overlap)
        text = next(item["markdownText"] for item in tiles if item["visualType"] == "markdownCard")
        self.assertIn("never add their costs together", text)
        self.assertIn("not represent historical tag inheritance", text)
        self.assertIn("not evidence of no Azure spend", text)
        self.assertIn("TOP filter bar", text)
        self.assertIn("column funnel", text)

    def test_snapshot_freshness_is_visible(self):
        query = self.queries["a6c90100-487a-4e37-9b5a-21bbc3b67a29"]["text"]
        self.assertIn("Subscriptions == 0", query)
        self.assertIn("SnapshotAge > 1d", query)
        self.assertIn("Update-SubscriptionTagInventory.ps1", query)
        self.assertIn("ResourceTagInventory", query)
        self.assertIn("countif(isnotempty(ResourceId))", query)

    def test_resource_table_uses_all_top_filters_and_distinguishes_cost_bases(self):
        query = self.queries["a6c90100-487a-4e37-9b5a-21bbc3b67a50"]
        for name in ("selectedTagSource", "selectedTagSubscriptions", "selectedTagNames", "selectedTagPairs"):
            self.assertIn(name, query["usedVariables"])
            self.assertIn(name, query["text"])
        for name in ("MatchingTagBilledCost", "FullResourceBilledCost", "CurrentResourceTags", "ResourceStatus", "TagBasis"):
            self.assertIn(name, query["text"])
        self.assertIn("join kind=fullouter inventory on SubscriptionId, ResourceId", self.setup)
        self.assertIn('"(Charges without resource ID)"', self.setup)
        self.assertIn('where isnotempty(ResourceId)', self.setup)
        self.assertIn('"Current resource tags (no cost records)"', self.setup)

    def test_subscription_tables_cross_filter_by_unique_id(self):
        for suffix in ("12", "13"):
            tile = next(item for item in self.dashboard["tiles"] if item["id"].endswith("b67a" + suffix))
            self.assertFalse(tile["visualOptions"]["crossFilterDisabled"])
            self.assertEqual(tile["visualOptions"]["crossFilter"], [{
                "interaction": "column", "property": "SubscriptionId",
                "parameterId": self.parameters["selectedTagSubscriptions"]["id"],
            }])


if __name__ == "__main__":
    unittest.main()
