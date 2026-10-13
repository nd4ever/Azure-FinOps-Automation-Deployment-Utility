using System.Text.Json;
using System.Text.RegularExpressions;
using Kusto.Language;
using Kusto.Language.Editor;

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
""";
using var dashboard = JsonDocument.Parse(File.ReadAllText(Path.Combine(root, "finops-hub-dashboard.json")));
var queries = dashboard.RootElement.GetProperty("queries").EnumerateArray()
    .ToDictionary(item => item.GetProperty("id").GetString()!, item => item);
var bases = dashboard.RootElement.GetProperty("baseQueries").EnumerateArray()
    .Where(item => item.GetProperty("variableName").GetString() is "TagPeriodCosts" or "TagCostRows" or "FilteredTagCostRows")
    .ToDictionary(item => item.GetProperty("variableName").GetString()!,
        item => item.GetProperty("queryId").GetString()!);
var failures = 0;
var checkedQueries = 0;
foreach (var query in queries.Values.Where(item => item.GetProperty("id").GetString()!.StartsWith("a6c90100-"))) {
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
    var text = fixtures + "\n" + definitions + "\n" + string.Join("\n", declarations) + "\n" + query.GetProperty("text").GetString();
    var diagnostics = KustoCode.ParseAndAnalyze(text).GetDiagnostics()
        .Where(diagnostic => diagnostic.Severity == DiagnosticSeverity.Error).ToArray();
    foreach (var diagnostic in diagnostics) {
        Console.Error.WriteLine($"{query.GetProperty("id").GetString()}: {diagnostic.Message} at {diagnostic.Start}");
        failures++;
    }
    checkedQueries++;
}
var assertions = File.ReadAllText(Path.Combine(root, "tests", "resource_cost_assertions.kql"));
var assertionQuery = fixtures + "\n" + definitions + "\n" + assertions;
foreach (var diagnostic in KustoCode.ParseAndAnalyze(assertionQuery).GetDiagnostics()
    .Where(diagnostic => diagnostic.Severity == DiagnosticSeverity.Error)) {
    Console.Error.WriteLine($"Resource assertions: {diagnostic.Message} at {diagnostic.Start}");
    failures++;
}
if (failures != 0) throw new Exception($"{failures} KQL syntax/semantic errors.");
if (args.Length == 2) File.WriteAllText(args[1], assertionQuery);
Console.WriteLine($"PASS: {checkedQueries} dashboard queries, all four Hub functions and resource assertions analyzed with typed fixtures.");
