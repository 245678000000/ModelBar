namespace ModelBar.Core.Tests;

public class TomlDocumentTests
{
    private const string Sample = """
        # top comment
        model = "gpt-6.1-sol"
        model_reasoning_effort = "xhigh"
        notify = [
          "/path/with [brackets]/client",
          "turn-ended"
        ]
        service_tier = "priority"

        # comment for the OpenAI table
        [model_providers.OpenAI]
        name = "OpenAI"
        base_url = "https://example.com/v1"

        [model_providers.magpie]
        http_headers = { "x-a" = "b" }
        wire_api = "responses"

        [[hooks]]
        text = '''
        [not.a.table]
        model = "nope"
        '''

        """;

    [Fact]
    public void ReadsTopLevelAndTableValues()
    {
        var document = new TomlDocument(Sample);
        Assert.Equal("gpt-6.1-sol", document.GetString("model"));
        Assert.Equal("https://example.com/v1", document.GetString("base_url", "model_providers.OpenAI"));
        Assert.Equal("responses", document.GetString("wire_api", "model_providers.magpie"));
        Assert.Contains("turn-ended", document.RawValue("notify"));
    }

    [Fact]
    public void MultilineStringContentIsNotATable() => Assert.False(new TomlDocument(Sample).HasTable("not.a.table"));

    [Fact]
    public void InsertsNewKeyBeforeFirstTable()
    {
        var document = new TomlDocument(Sample);
        document.SetTopLevel("model_provider", "\"modelbar\"");
        var text = document.Text;
        Assert.True(text.IndexOf("model_provider = \"modelbar\"", StringComparison.Ordinal) < text.IndexOf("[model_providers", StringComparison.Ordinal));
        Assert.Contains("service_tier = \"priority\"\nmodel_provider", text.Replace("\r\n", "\n"));
    }

    [Fact]
    public void InsertsIntoFileThatStartsWithTable()
    {
        var document = new TomlDocument("# about a\n[a]\nb = 1\n");
        document.SetTopLevel("model", "\"m\"");
        Assert.Equal("model = \"m\"\n# about a\n[a]\nb = 1\n", document.Text);
    }

    [Fact]
    public void ReplacesAndRemovesWithoutTouchingOthers()
    {
        var document = new TomlDocument(Sample);
        document.SetTopLevel("model", "\"other\"");
        document.SetTopLevel("model_reasoning_effort", null);
        document.SetTopLevel("notify", null);
        Assert.Equal("other", document.GetString("model"));
        Assert.Null(document.RawValue("model_reasoning_effort"));
        Assert.DoesNotContain("turn-ended", document.Text);
        Assert.Equal("priority", document.GetString("service_tier"));
        Assert.Equal("OpenAI", document.GetString("name", "model_providers.OpenAI"));
    }

    [Fact]
    public void RemoveTableKeepsCommentOfNextTable()
    {
        var document = new TomlDocument("[x]\na = 1\n\n# about y\n[y]\nb = 2\n");
        document.RemoveTable("x");
        Assert.Contains("# about y\n[y]", document.Text);
        Assert.False(document.HasTable("x"));
    }

    [Fact]
    public void RemoveTableAlsoRemovesSubtablesAndMarker()
    {
        var document = new TomlDocument("a = 1\n\n# marker\n[p.m]\nb = 2\n\n[p.m.auth]\nc = 3\n");
        document.RemoveTable("p.m", "# marker");
        Assert.Equal("a = 1\n", document.Text);
    }

    [Fact]
    public void DoesNotRemoveTableWithSharedPrefix()
    {
        var document = new TomlDocument("[p.m]\na = 1\n\n[p.mx]\nb = 2\n");
        document.RemoveTable("p.m");
        Assert.True(document.HasTable("p.mx"));
        Assert.False(document.HasTable("p.m"));
    }

    [Fact]
    public void SetsInsertsAndRemovesInsideTables()
    {
        var document = new TomlDocument("[a]\nx = 1\n\n[b]\ny = 2\n");
        document.Set("x", "9", "a");
        document.Set("z", "3", "a");
        Assert.Equal("[a]\nx = 9\nz = 3\n\n[b]\ny = 2\n", document.Text);
        document.Set("z", null, "a");
        Assert.Equal("[a]\nx = 9\n\n[b]\ny = 2\n", document.Text);
        document.Set("n", "1", "c");
        Assert.Equal("1", document.RawValue("n", "c"));
    }

    [Fact]
    public void RemovingLastKeyRemovesEmptyTable()
    {
        var document = new TomlDocument("[a]\nx = 1\n\n[b]\ny = 2\n");
        document.Set("y", null, "b");
        Assert.Equal("[a]\nx = 1\n", document.Text);
    }

    [Fact]
    public void PreservesCrlfLineEndings()
    {
        const string text = "model = \"a\"\r\n\r\n[t]\r\nb = 1\r\n";
        var document = new TomlDocument(text);
        document.SetTopLevel("model", "\"b\"");
        Assert.Equal("model = \"b\"\r\n\r\n[t]\r\nb = 1\r\n", document.Text);
        Assert.Equal("1", document.RawValue("b", "t"));
    }

    [Theory]
    [InlineData("plain")]
    [InlineData("with \"quote\"")]
    [InlineData(@"C:\Users\John Doe\key")]
    [InlineData("模型 · 名称")]
    public void QuotingRoundTrips(string value) => Assert.Equal(value, TomlDocument.ParseString(TomlDocument.Quote(value)));
}
