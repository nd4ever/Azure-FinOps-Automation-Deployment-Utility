import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SUMMARY_QUERIES = {
    "c077a6d4-719f-42fe-b39b-36f77dc68976",
    "3d947a7c-edca-46b5-a862-de77a725c85f",
}


class DashboardTotalsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dashboard = json.loads((ROOT / "finops-hub-dashboard.json").read_text(encoding="utf-8"))
        cls.queries = {query["id"]: query for query in cls.dashboard["queries"]}
        cls.bases = {
            base["variableName"]: cls.queries[base["queryId"]]
            for base in cls.dashboard["baseQueries"]
        }
        cls.tables = [tile for tile in cls.dashboard["tiles"] if tile["visualType"] == "table"]

    def test_every_additive_table_has_currency_safe_totals_sorted_last(self):
        self.assertEqual(len(self.tables), 32)
        for tile in self.tables:
            query = self.queries[tile["queryRef"]["queryId"]]
            text = query["text"]
            with self.subTest(table=tile["title"], query=query["id"]):
                if query["id"] in SUMMARY_QUERIES:
                    self.assertNotIn("_IsTotal", text)
                    continue
                self.assertIn("'Total'", text)
                self.assertIn("_IsTotal = true", text)
                self.assertIn("_IsTotal = false", text)
                self.assertIn("| order by _IsTotal asc,", text)
                if "let subscriptionInventory =" in text:
                    self.assertTrue(text.endswith("| project Inventory, Subscriptions, Resources, SnapshotAt, SnapshotAge, Status"))
                else:
                    self.assertIn("| project-away _IsTotal", text)
                    self.assertRegex(text, r"\bby [^\n]*BillingCurrency")

    def test_tag_totals_preserve_original_records_and_exact_filter_keys(self):
        base = self.bases["MatchingTagPeriodCosts"]
        text = base["text"]
        self.assertIn("TagPeriodCosts", base["usedVariables"])
        self.assertIn("mv-apply _TagKey", text)
        self.assertIn("| summarize _MatchesResourceTag = countif(", text)
        self.assertIn("_MatchesSubscriptionTag or _MatchesResourceTag", text)
        self.assertIn("pack_array('Resource/cost', _HasTag, _TagName, _TagValue)", text)
        self.assertIn("pack_array(_HasTag, _TagName)", text)
        for variable in ("selectedTagSource", "selectedTagSubscriptions", "selectedTagNames", "selectedTagPairs"):
            self.assertIn(variable, base["usedVariables"])
            self.assertIn(variable, text)
        self.assertNotIn("distinct", text)
        self.assertNotIn("summarize by", text)
        for suffix in ("27", "50"):
            query = self.queries[f"a6c90100-487a-4e37-9b5a-21bbc3b67a{suffix}"]
            self.assertIn("MatchingTagPeriodCosts", query["usedVariables"])
            self.assertIn("MatchingTagPeriodCosts\n", query["text"])

    def test_totals_do_not_supply_fake_subscription_ids_for_cross_filtering(self):
        for suffix in ("27", "28"):
            text = self.queries[f"a6c90100-487a-4e37-9b5a-21bbc3b67a{suffix}"]["text"]
            self.assertIn("SubscriptionName = 'Total', SubscriptionId = ''", text)
        resource = self.queries["a6c90100-487a-4e37-9b5a-21bbc3b67a50"]["text"]
        self.assertIn("by SubscriptionId, ResourceId, BillingCurrency", resource)
        self.assertIn("ResourceBilledCost = take_any(ResourceBilledCost)", resource)
        self.assertIn("TagCostRecordCount = count() by BillingCurrency", resource)

    def test_monthly_totals_aggregate_long_form_before_dynamic_pivot(self):
        pivots = [
            self.queries[tile["queryRef"]["queryId"]]["text"]
            for tile in self.tables
            if tile["queryRef"]["queryId"] not in SUMMARY_QUERIES
            if "| evaluate pivot(" in self.queries[tile["queryRef"]["queryId"]]["text"]
        ]
        self.assertEqual(len(pivots), 12)
        for text in pivots:
            self.assertIn("by ChargePeriod, BillingCurrency", text)
            self.assertIn(
                "summarize EffectiveCost = round(sum(EffectiveCost), 2) by ChargePeriod, BillingCurrency",
                text,
            )
            self.assertIn("sum(EffectiveCost), _IsTotal, BillingCurrency,", text)
            self.assertNotIn("sum(Total)", text)
        chargebacks = [text for text in pivots if "chargebackRows" in text]
        self.assertEqual(len(chargebacks), 2)
        for text in chargebacks:
            self.assertIn("summarize _CurrencyCount = sum(Count) by BillingCurrency", text)
            self.assertIn("Percent = round(100.0 * Count / _CurrencyCount, 3)", text)
            self.assertNotIn("Percentage =", text)
            self.assertEqual(text.count("Total = column_ifexists('Total', real(0))"), 2)
            self.assertIn(
                "Total = column_ifexists('Total', real(0))\n| extend Count", text
            )
            self.assertIn(
                "| where _IsTotal\n| extend Total = column_ifexists('Total', real(0))",
                text,
            )

    def test_inventory_uses_latest_snapshots_and_distinct_subscription_totals(self):
        text = self.queries["a6c90100-487a-4e37-9b5a-21bbc3b67a29"]["text"]
        self.assertIn("arg_max(SnapshotAt, *) by SubscriptionId, ResourceId", text)
        self.assertIn("summarize Subscriptions = count_distinct(SubscriptionId)", text)
        self.assertIn("countif(isnotempty(ResourceId))", text)
        self.assertNotIn("sum(Subscriptions)", text)

    def test_query_and_base_ids_are_unique_and_references_resolve(self):
        for collection in ("queries", "baseQueries"):
            ids = [item["id"] for item in self.dashboard[collection]]
            self.assertEqual(len(ids), len(set(ids)))
        for base in self.dashboard["baseQueries"]:
            self.assertIn(base["queryId"], self.queries)
        for tile in self.tables:
            self.assertIn(tile["queryRef"]["queryId"], self.queries)


if __name__ == "__main__":
    unittest.main()
