using System.Text.Json;
using System.Text.RegularExpressions;
using Kusto.Language;
using Kusto.Language.Editor;
using Kusto.Language.Symbols;

var root = args.Length >= 1 ? args[0] : Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", ".."));
var setup = File.ReadAllText(Path.Combine(root, "fabric", "finops-hub-subscription-tags.kql"));
var functionPattern = @"(?m)^((?:Subscription|Resource)(?:Tag)?Costs)\(([^)]*)\)\s*\{([\s\S]*?)^\}";
var functions = Regex.Matches(setup, functionPattern);
if (functions.Count != 4) throw new Exception("Expected all four subscription/resource cost functions.");
var definitions = string.Join("\n", functions.Select(match =>
    $"let {match.Groups[1].Value} = ({match.Groups[2].Value}) {{{match.Groups[3].Value}}};"));
var fixtures = """
let Costs = () {
    datatable(ChargePeriodStart:datetime, SubAccountId:string, SubAccountName:string,
        BillingCurrency:string, BilledCost:real, EffectiveCost:real, Tags:dynamic,
        ResourceId:string, ResourceName:string, x_ResourceGroupName:string, ResourceType:string)
    [
        datetime(2026-10-01), '/subscriptions/sub1', 'Same name', 'USD', 10.0, 8.0, dynamic({"Environment":"Prod","Owner":"TeamA"}), '/subscriptions/sub1/resourceGroups/rg/providers/test/vms/vm1', 'Old vm name', 'rg', 'test/vms',
        datetime(2026-10-02), '/subscriptions/sub1', 'Same name', 'USD', 20.0, 18.0, dynamic({"Environment":"Dev","Owner":"Prod"}), '/subscriptions/sub1/resourceGroups/rg/providers/test/vms/vm1', 'Old vm name', 'rg', 'test/vms',
        datetime(2026-10-03), '/subscriptions/sub1', 'Same name', 'EUR', 5.0, 4.0, dynamic({}), '/subscriptions/sub1/resourcegroups/rg/providers/test/vms/vm1', 'Old vm name', 'rg', 'test/vms',
        datetime(2026-10-01), '/subscriptions/sub2', 'Same name', 'USD', 7.0, 6.0, dynamic({"(No tags)":""}), '/subscriptions/sub2/resourcegroups/rg/providers/test/vms/vm1', 'vm1', 'rg', 'test/vms',
        datetime(2026-10-04), '/subscriptions/sub1', 'Same name', 'USD', 3.0, 3.0, dynamic({}), '', '', '', '',
        datetime(2026-10-04), '/subscriptions/sub1', 'Same name', 'USD', 11.0, 9.0, dynamic({"Environment":"Prod"}), '/subscriptions/sub1/resourcegroups/rg/providers/test/vms/deleted', 'deleted', 'rg', 'test/vms'
    ]
};
let SubscriptionTagInventory = datatable(SubscriptionId:string, SubscriptionName:string, Tags:dynamic, SnapshotAt:datetime)
[
    'sub1', 'Same name', dynamic({"Environment":"Production","CostCenter":"Finance"}), datetime(2026-10-13),
    'sub2', 'Same name', dynamic({}), datetime(2026-10-13),
    'sub3', 'No exports', dynamic({"Environment":"Prod"}), datetime(2026-10-13)
];
let ResourceTagInventory = datatable(SubscriptionId:string, SubscriptionName:string,
    ResourceId:string, ResourceName:string, ResourceGroup:string, ResourceType:string,
    Location:string, Tags:dynamic, SnapshotAt:datetime)
[
    'sub1', 'Same name', '', '', '', '', '', dynamic({}), datetime(2026-10-13),
    'sub1', 'Same name', '/subscriptions/sub1/resourcegroups/rg/providers/test/vms/vm1', 'vm1', 'rg', 'test/vms', 'centralus', dynamic({"Environment":"Staging","Owner":"CurrentTeam"}), datetime(2026-10-13),
    'sub1', 'Same name', '/subscriptions/sub1/resourcegroups/rg/providers/test/vms/noexports', 'noexports', 'rg', 'test/vms', 'centralus', dynamic({"Environment":"Prod","Owner":"TeamA"}), datetime(2026-10-13),
    'sub1', 'Same name', '/subscriptions/sub1/resourcegroups/rg/providers/test/vms/untagged', 'untagged', 'rg', 'test/vms', 'centralus', dynamic({}), datetime(2026-10-13),
    'sub2', 'Same name', '', '', '', '', '', dynamic({}), datetime(2026-10-13),
    'sub2', 'Same name', '/subscriptions/sub2/resourcegroups/rg/providers/test/vms/vm1', 'vm1', 'rg', 'test/vms', 'centralus', dynamic({"(No tags)":""}), datetime(2026-10-13),
    'sub3', 'No exports', '', '', '', '', '', dynamic({}), datetime(2026-10-13)
];
let tagCostStart = datetime(2026-10-01);
let tagCostEnd = datetime(2026-11-01);
let selectedBillingCurrency = '';
let selectedTagSource = 'Both';
let selectedTagSubscriptions = dynamic(null);
let selectedTagNames = dynamic(null);
let selectedTagPairs = dynamic(null);
let selectedChargePeriod = 'MonthToDate';
let numberOfMonths = 1;
let numberOfDays = 28;
let Costs_v1_2 = Costs()
| extend ListCost = BilledCost, ContractedCost = BilledCost, CommitmentDiscountType = '',
    ServiceName = 'Test service', ServiceCategory = 'Compute', RegionName = 'centralus',
    ChargeCategory = 'Usage', CommitmentDiscountStatus = '', CommitmentDiscountId = '',
    CommitmentDiscountName = '', CommitmentDiscountCategory = '', ProviderName = 'Microsoft',
    PricingCategory = 'Standard', PricingQuantity = 1.0, PricingUnit = 'Hours',
    ConsumedQuantity = 1.0, ConsumedUnit = 'Hours', ListUnitPrice = 1.0, ContractedUnitPrice = 1.0,
    x_EffectiveUnitPrice = 1.0, x_BilledUnitPrice = 1.0, x_SkuTerm = 12,
    x_SkuDescription = 'Test SKU', x_SkuOrderId = 'order1', ChargeFrequency = 'Usage-Based',
    ChargeClass = '', x_ResourceParentId = '', x_ResourceParentName = '', x_ToolkitVersion = '',
    x_SkuLicenseStatus = 'Enabled', x_SkuLicenseType = 'Windows', x_SkuInstanceType = 'Test size',
    x_SkuCoreCount = 2, x_SkuLicenseQuantity = 4, x_SkuLicenseUnusedQuantity = 2,
    x_BillingProfileId = 'account1', x_SourceChanges = '', x_PublisherCategory = '',
    x_PricingBlockSize = 1, x_PricingUnitDescription = '', x_BillingAccountAgreement = 'agreement1';
let CostsPlus = Costs_v1_2 | extend BillingPeriodStart = ChargePeriodStart;
let percentstring = (num:real) { strcat(round(num * 100, 2), '%') };
let arraystring = (values:dynamic) { strcat_array(values, ', ') };
""";
var globals = GlobalState.Default.WithDatabase(new DatabaseSymbol("Ingestion",
    new FunctionSymbol("parse_resourceid", ScalarTypes.Dynamic, new Parameter("resourceId", ScalarTypes.Dynamic))));
using var dashboard = JsonDocument.Parse(File.ReadAllText(Path.Combine(root, "finops-hub-dashboard.json")));
var queries = dashboard.RootElement.GetProperty("queries").EnumerateArray()
    .ToDictionary(item => item.GetProperty("id").GetString()!, item => item);
var bases = dashboard.RootElement.GetProperty("baseQueries").EnumerateArray()
    .Where(item => item.GetProperty("variableName").GetString() is "TagPeriodCosts" or "TagCostRows" or "FilteredTagCostRows" or "MatchingTagPeriodCosts"
        or "ChargePeriodBounds" or "SelectedPeriodCosts" or "CostsByMonth" or "CostsByDay" or "CostsByDayAHB" or "CostsThisMonth")
    .ToDictionary(item => item.GetProperty("variableName").GetString()!,
        item => item.GetProperty("queryId").GetString()!);
var failures = 0;
var checkedQueries = 0;
var periodQueryIds = bases.Where(item => item.Key is "ChargePeriodBounds" or "SelectedPeriodCosts" or "CostsThisMonth"
    or "CostsByMonth" or "CostsByDay" or "CostsByDayAHB").Select(item => item.Value).ToHashSet();
var tableQueryIds = dashboard.RootElement.GetProperty("tiles").EnumerateArray()
    .Where(item => item.GetProperty("visualType").GetString() == "table")
    .Select(item => item.GetProperty("queryRef").GetProperty("queryId").GetString()!).ToHashSet();
foreach (var query in queries.Values.Where(item => item.GetProperty("id").GetString()!.StartsWith("a6c90100-")
    || item.GetProperty("id").GetString()!.StartsWith("b72860dc-") || periodQueryIds.Contains(item.GetProperty("id").GetString()!)
    || tableQueryIds.Contains(item.GetProperty("id").GetString()!)
    || item.GetProperty("id").GetString() is "f062533b-8c94-412f-bf83-0eb5cd06063d" or "e8b343dc-7430-4487-8d44-ef48ac454f2d")) {
    var declarations = new List<string>();
    var emitted = new HashSet<string>();
    void IncludeBase(string name) {
        if (!bases.TryGetValue(name, out var id) || !emitted.Add(name)) return;
        var dependency = queries[id];
        foreach (var variable in dependency.GetProperty("usedVariables").EnumerateArray())
            IncludeBase(variable.GetString()!);
        declarations.Add($"let {name} = ({dependency.GetProperty("text").GetString()});");
    }
    foreach (var variable in query.GetProperty("usedVariables").EnumerateArray())
        IncludeBase(variable.GetString()!);
    var queryText = query.GetProperty("text").GetString()!;
    queryText = Regex.Replace(queryText, @"(?m)^Costs$", "Costs_v1_2");
    var text = fixtures + "\n" + definitions + "\n" + string.Join("\n", declarations) + "\n" + queryText;
    var diagnostics = KustoCode.ParseAndAnalyze(text, globals).GetDiagnostics()
        .Where(diagnostic => diagnostic.Severity == DiagnosticSeverity.Error).ToArray();
    foreach (var diagnostic in diagnostics) {
        Console.Error.WriteLine($"{query.GetProperty("id").GetString()}: {diagnostic.Message} at {diagnostic.Start}");
        failures++;
    }
    checkedQueries++;
}
var assertions = File.ReadAllText(Path.Combine(root, "tests", "resource_cost_assertions.kql"));
var periodFunctions = """
let boundaryCosts = datatable(ChargePeriodStart:datetime, BillingPeriodStart:datetime, BilledCost:real, EffectiveCost:real, BillingCurrency:string)
[
    datetime(2026-09-30T23:59:59.9999999Z), datetime(2026-09-01), 100.0, 80.0, 'USD',
    datetime(2026-10-01), datetime(2026-09-01), 10.0, 8.0, 'USD',
    datetime(2026-10-13T23:59:59.9999999Z), datetime(2026-10-01), 20.0, 16.0, 'USD',
    datetime(2026-10-14), datetime(2026-10-01), 30.0, 24.0, 'USD',
    datetime(2026-10-14T12:00:00Z), datetime(2026-10-01), 40.0, 32.0, 'USD',
    datetime(2026-11-01), datetime(2026-11-01), 50.0, 40.0, 'USD'
];
""" + "\nlet ResolveChargePeriod = (selectedChargePeriod:string, tagCostStart:datetime, tagCostEnd:datetime, asOf:datetime) {\n"
    + queries[bases["ChargePeriodBounds"]].GetProperty("text").GetString()!.Replace("now()", "asOf") + "\n};\n"
    + "let SelectPeriodCosts = (selectedChargePeriod:string, tagCostStart:datetime, tagCostEnd:datetime, asOf:datetime) {\n"
    + "let ChargePeriodBounds = ResolveChargePeriod(selectedChargePeriod, tagCostStart, tagCostEnd, asOf);\n"
    + queries[bases["SelectedPeriodCosts"]].GetProperty("text").GetString()!.Replace("CostsPlus", "boundaryCosts") + "\n};\n";
periodFunctions += "let FixedCurrentMonthCosts = (asOf:datetime, selectedBillingCurrency:string) {\n"
    + queries[bases["CostsThisMonth"]].GetProperty("text").GetString()!
        .Replace("Costs_v1_2", "boundaryCosts").Replace("now()", "asOf") + "\n};\n";
var dateAssertions = File.ReadAllText(Path.Combine(root, "tests", "date_range_assertions.kql"));
string BuildTagTotalsFunction(string name, string queryId)
{
    var body = new List<string>
    {
        $"let {name} = (selectedTagSource:string, selectedTagSubscriptions:dynamic, selectedTagNames:dynamic, selectedTagPairs:dynamic, selectedBillingCurrency:string, duplicateCharges:bool) {{",
        "let ChargePeriodBounds = print StartDate = tagCostStart, EndDate = tagCostEnd;",
        "let originalPeriodCosts = (" + queries[bases["TagPeriodCosts"]].GetProperty("text").GetString() + ");",
        "let TagPeriodCosts = union originalPeriodCosts, (originalPeriodCosts | where duplicateCharges);"
    };
    foreach (var variable in new[] { "TagCostRows", "FilteredTagCostRows", "MatchingTagPeriodCosts" })
        body.Add($"let {variable} = (\n{queries[bases[variable]].GetProperty("text").GetString()}\n);");
    body.Add(queries[queryId].GetProperty("text").GetString()!);
    body.Add("};");
    return string.Join("\n", body);
}
var totalsFunctions = BuildTagTotalsFunction("TagTotals", "a6c90100-487a-4e37-9b5a-21bbc3b67a27") + "\n"
    + BuildTagTotalsFunction("SubscriptionTotals", "a6c90100-487a-4e37-9b5a-21bbc3b67a28") + "\n"
    + BuildTagTotalsFunction("ResourceTotals", "a6c90100-487a-4e37-9b5a-21bbc3b67a50") + "\n"
    + "let InventoryTotals = () {\n"
    + queries["a6c90100-487a-4e37-9b5a-21bbc3b67a29"].GetProperty("text").GetString() + "\n};\n"
    + "let MonthlyTotals = () {\nlet CostsByMonth = Costs_v1_2;\n"
    + queries["3886b5cd-34a8-42d7-9e16-33ea4d236953"].GetProperty("text").GetString() + "\n};\n"
    + "let MonthlyFractionalTotals = () {\n"
    + "let seed = Costs_v1_2 | take 1;\n"
    + "let CostsByMonth = union (seed | extend EffectiveCost = 0.1, SubAccountId = 'fraction1', SubAccountName = 'Fraction 1'),"
    + " (seed | extend EffectiveCost = 0.2, SubAccountId = 'fraction2', SubAccountName = 'Fraction 2');\n"
    + queries["3886b5cd-34a8-42d7-9e16-33ea4d236953"].GetProperty("text").GetString() + "\n};\n";
var totalsAssertions = File.ReadAllText(Path.Combine(root, "tests", "dashboard_totals_assertions.kql"));
var assertionQuery = fixtures + "\n" + definitions + "\n" + periodFunctions + "\n" + totalsFunctions
    + "\nlet resourceChecks = () {\n" + assertions + "\n};\n"
    + "let dateChecks = () {\n" + dateAssertions + "\n};\n"
    + "let totalsChecks = () {\n" + totalsAssertions + "\n};\n"
    + "union resourceChecks(), dateChecks(), totalsChecks()\n| order by Check asc";
foreach (var diagnostic in KustoCode.ParseAndAnalyze(assertionQuery).GetDiagnostics()
    .Where(diagnostic => diagnostic.Severity == DiagnosticSeverity.Error)) {
    Console.Error.WriteLine($"Resource/date/totals assertions: {diagnostic.Message} at {diagnostic.Start}");
    failures++;
}
var costPrefix = queries["eb9259cc-05b7-4441-a66d-a29026fe371b"].GetProperty("text").GetString()!.Split("| as filteredCosts")[0];
var prefixQuery = fixtures + "\n"
    + "let monthsago = (months:int) { startofmonth(now(), -months) };\n"
    + "let ChargePeriodBounds = (" + queries[bases["ChargePeriodBounds"]].GetProperty("text").GetString() + ");\n"
    + costPrefix;
foreach (var diagnostic in KustoCode.ParseAndAnalyze(prefixQuery).GetDiagnostics()
    .Where(diagnostic => diagnostic.Severity == DiagnosticSeverity.Error)) {
    Console.Error.WriteLine($"CostsPlus date filter: {diagnostic.Message} at {diagnostic.Start}");
    failures++;
}
if (failures != 0) throw new Exception($"{failures} KQL syntax/semantic errors.");
if (args.Length == 2) File.WriteAllText(args[1], assertionQuery);
Console.WriteLine($"PASS: {checkedQueries} dashboard queries (including all {tableQueryIds.Count} table queries), CostsPlus date filter, all four Hub functions and resource/date/totals assertions analyzed with typed fixtures (not executed).");
