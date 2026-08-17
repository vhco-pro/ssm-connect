using System.Text.Json;
using SSMConnect.Domain;
using SSMConnect.Workflow.Tests.Fixtures;

namespace SSMConnect.Workflow.Tests;

/// <summary>
/// Runs every workflow conformance fixture in <c>contracts/fixtures/workflows</c> against the real
/// workflow. This is the .NET half of AC-04: the macOS client runs the same fixtures against its
/// own implementation, and a disagreement between the two shows up here as a failing case.
/// </summary>
public sealed class ConformanceTests
{
    public static TheoryData<string> FixtureFiles()
    {
        var data = new TheoryData<string>();
        foreach (string path in FixturePaths.WorkflowFixtureFiles())
        {
            data.Add(Path.GetFileName(path));
        }

        return data;
    }

    [Fact]
    public void FixturesAreDiscovered()
    {
        IReadOnlyList<string> files = FixturePaths.WorkflowFixtureFiles();
        Assert.True(
            files.Count >= 28,
            $"Expected the contract fixtures to be copied next to the tests, found {files.Count} in " +
            $"'{FixturePaths.WorkflowsDirectory}'.");
    }

    [Theory]
    [MemberData(nameof(FixtureFiles))]
    public async Task Conforms(string fileName)
    {
        string path = Path.Combine(FixturePaths.WorkflowsDirectory, fileName);
        Fixture fixture = JsonSerializer.Deserialize<Fixture>(File.ReadAllText(path), Fixture.Options)
            ?? throw new InvalidOperationException($"Could not read fixture '{fileName}'.");

        FixtureRun run = await new FixtureRunner(fixture).RunAsync();

        AssertStates(fixture, run);
        AssertCalls(fixture, run);
        AssertForbiddenCalls(fixture, run);
        AssertTerminal(fixture, run);
    }

    private static void AssertStates(Fixture fixture, FixtureRun run)
    {
        string[] expected = fixture.Expect.States;
        string actual = string.Join(" → ", run.States);

        if (fixture.Expect.StatesAreExact)
        {
            Assert.True(
                expected.SequenceEqual(run.States),
                $"[{fixture.Id}] state sequence mismatch.\n" +
                $"  expected: {string.Join(" → ", expected)}\n" +
                $"  actual:   {actual}");
            return;
        }

        Assert.True(
            IsSubsequence(expected, run.States),
            $"[{fixture.Id}] expected states to appear in order as a subsequence.\n" +
            $"  expected: {string.Join(" → ", expected)}\n" +
            $"  actual:   {actual}");
    }

    private static bool IsSubsequence(IReadOnlyList<string> expected, IReadOnlyList<string> actual)
    {
        int cursor = 0;
        foreach (string state in actual)
        {
            if (cursor < expected.Count && expected[cursor] == state)
            {
                cursor++;
            }
        }

        return cursor == expected.Count;
    }

    /// <summary>
    /// Asserts the listed calls occurred in the listed relative order. <c>times</c> is the total
    /// count for that port and method; <c>with</c> asserts that at least one such call carried the
    /// listed arguments. Calls a fixture does not list are not constrained.
    /// </summary>
    private static void AssertCalls(Fixture fixture, FixtureRun run)
    {
        int cursor = -1;
        foreach (ExpectedCall expected in fixture.Expect.Calls)
        {
            int index = FindCall(run.Calls, expected, after: cursor);
            Assert.True(
                index >= 0,
                $"[{fixture.Id}] expected a call to {expected}{DescribeArguments(expected)} after position " +
                $"{cursor}, but the recorded sequence was:\n    {DescribeCalls(run.Calls)}");
            cursor = index;

            if (expected.Times is int times)
            {
                int actual = run.Recorder.CountOf(expected.Port, expected.Method);
                Assert.True(
                    actual == times,
                    $"[{fixture.Id}] expected {times} call(s) to {expected}, saw {actual}.\n" +
                    $"    {DescribeCalls(run.Calls)}");
            }
        }
    }

    private static void AssertForbiddenCalls(Fixture fixture, FixtureRun run)
    {
        foreach (ExpectedCall forbidden in fixture.Expect.ForbiddenCalls)
        {
            int actual = run.Recorder.CountOf(forbidden.Port, forbidden.Method);
            Assert.True(
                actual == 0,
                $"[{fixture.Id}] {forbidden} must not be called, but it was called {actual} time(s).");
        }
    }

    private static void AssertTerminal(Fixture fixture, FixtureRun run)
    {
        Terminal expected = fixture.Expect.Terminal;
        ConnectionWorkflow workflow = run.Workflow;

        Assert.True(
            workflow.State.Wire() == expected.State,
            $"[{fixture.Id}] terminal state was '{workflow.State.Wire()}', expected '{expected.State}'. " +
            $"States seen: {string.Join(" → ", run.States)}");

        if (expected.ErrorCategory is string category)
        {
            Assert.True(
                workflow.ErrorCategory.Wire() == category,
                $"[{fixture.Id}] error category was '{workflow.ErrorCategory.Wire()}', expected '{category}'. " +
                $"Message: {workflow.ErrorMessage ?? "<none>"}");
        }

        if (expected.ErrorMessageContains is string fragment)
        {
            Assert.True(
                workflow.ErrorMessage?.Contains(fragment, StringComparison.OrdinalIgnoreCase) == true,
                $"[{fixture.Id}] expected the error message to contain '{fragment}', got " +
                $"'{workflow.ErrorMessage ?? "<none>"}'.");
        }

        if (expected.WarningPresent is bool warning)
        {
            Assert.True(
                (workflow.WarningMessage is not null) == warning,
                $"[{fixture.Id}] expected warningPresent={warning}, warning was " +
                $"'{workflow.WarningMessage ?? "<none>"}'.");
        }

        if (expected.InstanceId is not null || ExpectsNullInstanceId(fixture))
        {
            Assert.True(
                workflow.InstanceId == expected.InstanceId,
                $"[{fixture.Id}] instance ID was '{workflow.InstanceId ?? "<null>"}', expected " +
                $"'{expected.InstanceId ?? "<null>"}'.");
        }

        if (expected.TunnelActive is bool tunnelActive)
        {
            Assert.True(
                workflow.TunnelActive == tunnelActive,
                $"[{fixture.Id}] expected tunnelActive={tunnelActive}, was {workflow.TunnelActive}.");
        }

        if (expected.PasswordInMemory is bool password)
        {
            Assert.True(
                (workflow.Password is not null) == password,
                $"[{fixture.Id}] expected passwordInMemory={password}, was {workflow.Password is not null}.");
        }
    }

    /// <summary>
    /// A fixture that explicitly writes <c>"instanceId": null</c> is asserting the field was
    /// cleared, which is different from not mentioning it at all.
    /// </summary>
    private static bool ExpectsNullInstanceId(Fixture fixture)
    {
        string raw = File.ReadAllText(Path.Combine(FixturePaths.WorkflowsDirectory, $"{fixture.Id}.json"));
        using JsonDocument document = JsonDocument.Parse(raw);
        return document.RootElement.TryGetProperty("expect", out JsonElement expect)
            && expect.TryGetProperty("terminal", out JsonElement terminal)
            && terminal.TryGetProperty("instanceId", out JsonElement instanceId)
            && instanceId.ValueKind == JsonValueKind.Null;
    }

    private static int FindCall(IReadOnlyList<RecordedCall> calls, ExpectedCall expected, int after)
    {
        for (int index = after + 1; index < calls.Count; index++)
        {
            RecordedCall call = calls[index];
            if (call.Port == expected.Port && call.Method == expected.Method && Matches(call, expected))
            {
                return index;
            }
        }

        return -1;
    }

    private static bool Matches(RecordedCall call, ExpectedCall expected)
    {
        if (expected.With is null)
        {
            return true;
        }

        foreach ((string name, JsonElement value) in expected.With)
        {
            if (!call.Arguments.TryGetValue(name, out object? actual))
            {
                return false;
            }

            string expectedText = value.ValueKind == JsonValueKind.String ? value.GetString() ?? "" : value.ToString();
            if (!string.Equals(Convert.ToString(actual, System.Globalization.CultureInfo.InvariantCulture),
                    expectedText, StringComparison.Ordinal))
            {
                return false;
            }
        }

        return true;
    }

    private static string DescribeArguments(ExpectedCall expected) =>
        expected.With is null
            ? string.Empty
            : " with " + string.Join(", ", expected.With.Select(pair => $"{pair.Key}={pair.Value}"));

    private static string DescribeCalls(IReadOnlyList<RecordedCall> calls) =>
        calls.Count == 0 ? "<no calls>" : string.Join("\n    ", calls.Select((call, i) => $"{i}: {call}"));
}
