import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class DateDashboardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dashboard = json.loads((ROOT / "finops-hub-dashboard.json").read_text(encoding="utf-8"))
        cls.queries = {q["id"]: q for q in cls.dashboard["queries"]}
        cls.bases = {
            b["variableName"]: cls.queries[b["queryId"]]
            for b in cls.dashboard["baseQueries"]
        }

    def test_global_presets_default_to_month_to_date(self):
        period = next(p for p in self.dashboard["parameters"] if p.get("variableName") == "selectedChargePeriod")
        self.assertEqual(period["defaultValue"], {"kind": "value", "value": "MonthToDate"})
        self.assertEqual(period["showOnPages"], {"kind": "all"})
        self.assertEqual(
            {v["value"] for v in period["dataSource"]["values"]},
            {"MonthToDate", "LastMonth", "Custom", "TrendControls"},
        )
        custom = next(p for p in self.dashboard["parameters"] if p.get("beginVariableName") == "tagCostStart")
        self.assertEqual(custom["kind"], "duration")
        self.assertEqual(custom["showOnPages"], {"kind": "all"})
        self.assertIn("exclusive", custom["description"])

    def test_calendar_bounds_and_half_open_charge_date_filter(self):
        bounds = self.bases["ChargePeriodBounds"]
        self.assertIn("startofmonth(now())", bounds["text"])
        self.assertIn("startofmonth(now(), -1)", bounds["text"])
        self.assertIn("'MonthToDate', now()", bounds["text"])
        self.assertIn("tagCostStart", bounds["text"])
        self.assertIn("tagCostEnd", bounds["text"])
        selected = self.bases["SelectedPeriodCosts"]["text"]
        self.assertIn("ChargePeriodStart >= toscalar(ChargePeriodBounds | project StartDate)", selected)
        self.assertIn("ChargePeriodStart < toscalar(ChargePeriodBounds | project EndDate)", selected)
        self.assertNotIn("BillingPeriodStart", selected)
        self.assertNotIn("between", selected)

    def test_trend_controls_do_not_truncate_explicit_ranges(self):
        for name in ("CostsByMonth", "CostsByDay"):
            query = self.bases[name]
            self.assertIn("SelectedPeriodCosts", query["usedVariables"])
            self.assertIn("selectedChargePeriod != 'TrendControls'", query["text"])
        self.assertEqual(self.bases["CostsByDayAHB"]["text"], "SelectedPeriodCosts")
        enriched = self.bases["CostsPlus"]["text"]
        self.assertIn("or (selectedChargePeriod != 'TrendControls'", enriched)
        self.assertIn("ChargePeriodBounds | project StartDate", enriched)
        self.assertIn("ChargePeriodBounds | project EndDate", enriched)

    def test_tag_totals_and_resources_share_global_bounds(self):
        for query in (
            self.bases["TagPeriodCosts"], self.bases["TagCostRows"],
            self.queries["a6c90100-487a-4e37-9b5a-21bbc3b67a50"],
        ):
            self.assertIn("ChargePeriodBounds", query["usedVariables"])
            self.assertNotIn("tagCostStart", query["usedVariables"])
            self.assertIn("toscalar(ChargePeriodBounds | project StartDate)", query["text"])
            self.assertIn("toscalar(ChargePeriodBounds | project EndDate)", query["text"])

    def test_fixed_month_views_do_not_depend_on_filtered_costs(self):
        self.assertEqual(self.bases["CostsLastMonth"]["usedVariables"], ["CostsPlus"])
        self.assertEqual(self.bases["CostsThisMonth"]["usedVariables"], ["selectedBillingCurrency"])
        fixed_summary = self.queries["e8b343dc-7430-4487-8d44-ef48ac454f2d"]
        self.assertEqual(fixed_summary["usedVariables"], ["CostsPlus"])
        self.assertIn("startofmonth(now(), -1)", fixed_summary["text"])
        for tile in self.dashboard["tiles"]:
            query = self.queries.get(tile.get("queryRef", {}).get("queryId"))
            if query and ("CostsLastMonth" in query["usedVariables"] or "CostsThisMonth" in query["usedVariables"]):
                self.assertIn("Fixed calendar-month", tile["description"])

    def test_invoicing_has_selected_totals_and_nonoverlapping_layout(self):
        selected = next(t for t in self.dashboard["tiles"] if t["title"] == "Selected-period cost")
        query = self.queries[selected["queryRef"]["queryId"]]
        self.assertEqual(query["usedVariables"], ["CostsByDay"])
        self.assertIn("by BillingCurrency", query["text"])
        self.assertIn("BilledCost", query["text"])
        self.assertIn("EffectiveCost", query["text"])
        self.assertIn("imported exports", selected["description"])
        tiles = [t for t in self.dashboard["tiles"] if t["pageId"] == selected["pageId"]]
        for index, first in enumerate(tiles):
            a = first["layout"]
            for second in tiles[index + 1:]:
                b = second["layout"]
                self.assertFalse(
                    a["x"] < b["x"] + b["width"] and b["x"] < a["x"] + a["width"]
                    and a["y"] < b["y"] + b["height"] and b["y"] < a["y"] + a["height"]
                )

    def test_new_resource_types_use_history_before_the_selected_window(self):
        query = self.queries["f062533b-8c94-412f-bf83-0eb5cd06063d"]
        self.assertIn("Costs_v1_2 | where isempty(selectedBillingCurrency)", query["text"])
        self.assertIn("ChargePeriodBounds | project StartDate", query["text"])
        self.assertIn("selectedBillingCurrency", query["usedVariables"])
        self.assertNotIn("CostsPlus", query["usedVariables"])

    def test_cost_cards_meet_fabric_runtime_minimum_size(self):
        cards = [
            tile for tile in self.dashboard["tiles"]
            if tile["id"] in {
                "b72860dc-526e-4c14-9556-000000000005",
                "acf2ca3d-9d8f-477f-b259-f3937bf938d4",
            }
        ]
        self.assertEqual(len(cards), 2)
        for card in cards:
            self.assertEqual(card["visualType"], "multistat")
            self.assertEqual(card["visualOptions"]["multiStat__slot"], {"width": 1, "height": 2})
            self.assertGreaterEqual(card["layout"]["width"], 3, card["title"])
            self.assertGreaterEqual(card["layout"]["height"], 6, card["title"])
        selected = next(card for card in cards if card["title"] == "Selected-period cost")
        self.assertEqual(selected["layout"], {"x": 0, "y": 3, "width": 4, "height": 8})
        fixed = next(card for card in cards if card["id"] == "acf2ca3d-9d8f-477f-b259-f3937bf938d4")
        self.assertIn("fixed comparison", fixed["title"])
        self.assertGreaterEqual(fixed["layout"]["y"], selected["layout"]["y"] + selected["layout"]["height"])

    def test_every_last_month_card_has_a_current_month_peer_above(self):
        last_month_tiles = [
            tile for tile in self.dashboard["tiles"]
            if "CostsLastMonth" in self.queries.get(tile.get("queryRef", {}).get("queryId"), {}).get("usedVariables", [])
            or tile.get("queryRef", {}).get("queryId") == "e8b343dc-7430-4487-8d44-ef48ac454f2d"
        ]
        current_month_tiles = [
            tile for tile in self.dashboard["tiles"]
            if "CostsThisMonth" in self.queries.get(tile.get("queryRef", {}).get("queryId"), {}).get("usedVariables", [])
        ]
        self.assertEqual(len(last_month_tiles), 3)
        self.assertEqual(len(current_month_tiles), len(last_month_tiles))
        for previous in last_month_tiles:
            query = self.queries[previous["queryRef"]["queryId"]]["text"]
            metric = "BilledCost" if "BilledCost" in query else "Subscriptions"
            peers = [
                tile for tile in current_month_tiles
                if tile["pageId"] == previous["pageId"]
                and metric in self.queries[tile["queryRef"]["queryId"]]["text"]
            ]
            self.assertEqual(len(peers), 1, previous["title"])
            current = peers[0]
            self.assertLessEqual(current["layout"]["y"] + current["layout"]["height"], previous["layout"]["y"])
            self.assertGreaterEqual(current["layout"]["height"], 6)
            self.assertIn("current month", current["title"].lower())
            self.assertIn("independent of charge period", current["description"].lower())
        counts = next(tile for tile in current_month_tiles if "Counts" in tile["title"])
        for column in ("Subscriptions", "ResourceGroups", "Resources", "Services"):
            self.assertIn(column, self.queries[counts["queryRef"]["queryId"]]["text"])

    def test_summary_month_sections_include_savings_and_do_not_overlap(self):
        current = next(
            tile for tile in self.dashboard["tiles"]
            if tile["id"] == "b72860dc-526e-4c14-9556-000000000013"
        )
        query = self.queries[current["queryRef"]["queryId"]]
        self.assertEqual(query["usedVariables"], ["CostsThisMonth"])
        for metric in ("Billed cost", "Effective cost", "Commitment savings", "Negotiated savings"):
            self.assertIn(metric, query["text"])
        self.assertIn("BillingCurrency", query["text"])
        self.assertIn("round(todouble(Values.Cost), 2)", query["text"])
        previous = self.queries["e8b343dc-7430-4487-8d44-ef48ac454f2d"]["text"]
        self.assertIn("ChargePeriodStart < startofmonth(now())", previous)
        tiles = [tile for tile in self.dashboard["tiles"] if tile["pageId"] == current["pageId"]]
        for index, first in enumerate(tiles):
            a = first["layout"]
            for second in tiles[index + 1:]:
                b = second["layout"]
                self.assertFalse(
                    a["x"] < b["x"] + b["width"] and b["x"] < a["x"] + a["width"]
                    and a["y"] < b["y"] + b["height"] and b["y"] < a["y"] + a["height"],
                    (first["title"], second["title"]),
                )

    def test_current_month_is_fixed_mtd_and_keeps_currency_separate(self):
        query = self.bases["CostsThisMonth"]
        self.assertIn("Costs_v1_2\n", query["text"])
        self.assertIn("ChargePeriodStart >= startofmonth(now()) and ChargePeriodStart < now()", query["text"])
        self.assertIn("BillingCurrency == selectedBillingCurrency", query["text"])
        self.assertEqual(query["usedVariables"], ["selectedBillingCurrency"])
        for name in ("selectedChargePeriod", "tagCostStart", "tagCostEnd", "numberOfDays", "numberOfMonths"):
            self.assertNotIn(name, query["text"])
        totals = self.queries["b72860dc-526e-4c14-9556-000000000006"]["text"]
        self.assertIn("by Month = startofmonth(ChargePeriodStart), BillingCurrency", totals)
        self.assertIn("format_datetime(Month, 'MMM yyyy')", totals)
        self.assertIn("BillingCurrency", totals.split("| project")[1])


if __name__ == "__main__":
    unittest.main()
