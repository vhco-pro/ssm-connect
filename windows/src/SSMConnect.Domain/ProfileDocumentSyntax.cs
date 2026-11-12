using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using YamlDotNet.Core;
using YamlDotNet.Core.Events;

namespace SSMConnect.Domain;

public enum ProfileFileFormat { Json, Yaml }

public static class ProfileDocumentSyntax
{
    public const int MaximumBytes = 256 * 1024;
    public const int MaximumDepth = 32;
    public const int MaximumNodes = 8192;
    private static readonly Regex NumberPattern = new(
        @"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$", RegexOptions.CultureInvariant);

    public static ProfileFileFormat FormatForPath(string path) => Path.GetExtension(path).ToLowerInvariant() switch
    {
        ".json" => ProfileFileFormat.Json,
        ".yaml" or ".yml" => ProfileFileFormat.Yaml,
        _ => throw new ProfilePortabilityException("Choose a .json, .yaml or .yml profile file."),
    };

    public static JsonObject Read(string text, ProfileFileFormat format)
    {
        if (Encoding.UTF8.GetByteCount(text) > MaximumBytes)
        {
            throw new ProfilePortabilityException("Profile files must be UTF-8 and at most 256 KiB.");
        }
        if (text.StartsWith('\uFEFF')) { text = text[1..]; }

        try
        {
            if (format == ProfileFileFormat.Json)
            {
                using JsonDocument json = JsonDocument.Parse(text, new JsonDocumentOptions { MaxDepth = MaximumDepth });
            }

            var parser = new Parser(new StringReader(text));
            parser.Consume<StreamStart>();
            parser.Consume<DocumentStart>();
            int nodes = 0;
            JsonNode? root = ReadNode(parser, 0, ref nodes);
            parser.Consume<DocumentEnd>();
            if (!parser.Accept<StreamEnd>(out _))
            {
                throw new ProfilePortabilityException("Use exactly one profile document per file.");
            }

            return root as JsonObject ?? throw ProfilePortabilityException.NotAnObject();
        }
        catch (JsonException) { throw ProfilePortabilityException.MalformedJson(); }
        catch (YamlException error)
        {
            throw new ProfilePortabilityException(
                $"Invalid profile syntax near line {error.Start.Line}, column {error.Start.Column}. Duplicate mapping keys are not allowed.");
        }
    }

    public static string Write(JsonObject document, ProfileFileFormat format)
    {
        string result;
        if (format == ProfileFileFormat.Json)
        {
            result = Ordered(document)!.ToJsonString(new JsonSerializerOptions { WriteIndented = true }) + "\n";
        }
        else
        {
            using var writer = new StringWriter(CultureInfo.InvariantCulture);
            var emitter = new Emitter(writer);
            emitter.Emit(new StreamStart());
            emitter.Emit(new DocumentStart());
            WriteNode(emitter, document);
            emitter.Emit(new DocumentEnd(true));
            emitter.Emit(new StreamEnd());
            result = writer.ToString().Replace("\r\n", "\n", StringComparison.Ordinal);
        }

        if (Encoding.UTF8.GetByteCount(result) > MaximumBytes)
        {
            throw new ProfilePortabilityException("The canonical profile exceeds the 256 KiB file limit.");
        }

        return result;
    }

    private static JsonNode? ReadNode(IParser parser, int depth, ref int nodes)
    {
        Count(ref nodes);
        if (parser.Current is NodeEvent node && (!node.Anchor.IsEmpty || !node.Tag.IsEmpty))
        {
            throw new ProfilePortabilityException("Explicit YAML tags, anchors and aliases are not supported.");
        }

        switch (parser.Current)
        {
            case Scalar:
                return ScalarValue(parser.Consume<Scalar>());
            case MappingStart:
                CheckDepth(depth + 1);
                parser.Consume<MappingStart>();
                var mapping = new JsonObject();
                while (!parser.Accept<MappingEnd>(out _))
                {
                    Count(ref nodes);
                    if (parser.Current is not Scalar key || !key.Anchor.IsEmpty || !key.Tag.IsEmpty
                        || key.Value == "<<" || mapping.ContainsKey(key.Value))
                    {
                        throw new ProfilePortabilityException("Profile mappings require unique string keys; aliases and merges are not supported.");
                    }
                    parser.Consume<Scalar>();
                    mapping.Add(key.Value, ReadNode(parser, depth + 1, ref nodes));
                }
                parser.Consume<MappingEnd>();
                return mapping;
            case SequenceStart:
                CheckDepth(depth + 1);
                parser.Consume<SequenceStart>();
                var array = new JsonArray();
                while (!parser.Accept<SequenceEnd>(out _)) { array.Add(ReadNode(parser, depth + 1, ref nodes)); }
                parser.Consume<SequenceEnd>();
                return array;
            default:
                throw new ProfilePortabilityException("YAML aliases and unsupported profile values are not allowed.");
        }
    }

    private static JsonNode? ScalarValue(Scalar scalar)
    {
        string text = scalar.Value;
        if (scalar.Style != ScalarStyle.Plain) { return JsonValue.Create(text); }
        if (text is "null" or "~" or "") { return null; }
        if (text == "true") { return JsonValue.Create(true); }
        if (text == "false") { return JsonValue.Create(false); }
        if (!NumberPattern.IsMatch(text)) { return JsonValue.Create(text); }
        string[] parts = text.Split('e', 'E');
        int exponent = 0;
        if (parts.Length == 2 && (!int.TryParse(parts[1], NumberStyles.AllowLeadingSign,
                CultureInfo.InvariantCulture, out exponent) || exponent is < -128 or > 127))
        {
            throw new ProfilePortabilityException("Profile numeric exponents must be between -128 and 127.");
        }
        string significand = parts[0];
        int point = significand.IndexOf('.');
        int fractionDigits = point < 0 ? 0 : significand.Length - point - 1;
        string digits = new(significand.Where(char.IsAsciiDigit).ToArray());
        int trailingZeros = digits.Length - digits.TrimEnd('0').Length;
        string coefficient = digits.Trim('0');
        int normalizedExponent = coefficient.Length == 0 ? 0 : exponent - fractionDigits + trailingZeros;
        if (coefficient.Length > 38 || normalizedExponent is < -128 or > 127)
        {
            throw new ProfilePortabilityException("Profile numbers must fit 38 significant decimal digits and exponent -128 through 127.");
        }
        if ((normalizedExponent >= 0 || coefficient.Length == 0)
            && decimal.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out decimal integer)
            && integer == decimal.Truncate(integer) && integer >= int.MinValue && integer <= int.MaxValue)
        {
            return JsonValue.Create((int)integer);
        }

        // Keep the original JSON number rather than rounding unknown values through double/decimal.
        return JsonNode.Parse(text);
    }

    private static void Count(ref int nodes)
    {
        if (++nodes > MaximumNodes) { throw new ProfilePortabilityException("Profile files are limited to 8192 nodes."); }
    }

    private static void CheckDepth(int depth)
    {
        if (depth > MaximumDepth) { throw new ProfilePortabilityException("Profile files are limited to depth 32."); }
    }

    private static JsonNode? Ordered(JsonNode? node) => node switch
    {
        JsonObject obj => new JsonObject(obj.OrderBy(pair => pair.Key, StringComparer.Ordinal)
            .Select(pair => KeyValuePair.Create(pair.Key, Ordered(pair.Value)))),
        JsonArray array => new JsonArray(array.Select(Ordered).ToArray()),
        _ => node?.DeepClone(),
    };

    private static void WriteNode(IEmitter emitter, JsonNode? node)
    {
        switch (node)
        {
            case JsonObject obj:
                emitter.Emit(new MappingStart(AnchorName.Empty, TagName.Empty, true, MappingStyle.Block));
                foreach ((string key, JsonNode? child) in obj.OrderBy(pair => pair.Key, StringComparer.Ordinal))
                {
                    emitter.Emit(new Scalar(AnchorName.Empty, TagName.Empty, key, ScalarStyle.DoubleQuoted, false, true));
                    WriteNode(emitter, child);
                }
                emitter.Emit(new MappingEnd());
                break;
            case JsonArray array:
                emitter.Emit(new SequenceStart(AnchorName.Empty, TagName.Empty, true, SequenceStyle.Block));
                foreach (JsonNode? child in array) { WriteNode(emitter, child); }
                emitter.Emit(new SequenceEnd());
                break;
            case JsonValue value when value.GetValueKind() == JsonValueKind.String:
                emitter.Emit(new Scalar(AnchorName.Empty, TagName.Empty, value.GetValue<string>(),
                    ScalarStyle.DoubleQuoted, false, true));
                break;
            default:
                emitter.Emit(new Scalar(AnchorName.Empty, TagName.Empty, node?.ToJsonString() ?? "null",
                    ScalarStyle.Plain, true, false));
                break;
        }
    }
}
