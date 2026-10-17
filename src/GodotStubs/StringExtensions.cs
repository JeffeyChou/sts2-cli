namespace Godot;

public static class StringExtensions
{
    // Godot String.capitalize(): split snake/camel case into words, each lowercased with an initial capital.
    public static string Capitalize(this string instance)
    {
        var words = SplitWords(instance);
        return string.Join(" ", words.Select(w => w.Length == 0 ? w : char.ToUpperInvariant(w[0]) + w.Substring(1).ToLowerInvariant()));
    }

    // Godot String.to_snake_case()
    public static string ToSnakeCase(this string instance) => string.Join("_", SplitWords(instance).Select(w => w.ToLowerInvariant()));

    private static List<string> SplitWords(string s)
    {
        var words = new List<string>();
        var cur = new System.Text.StringBuilder();
        for (int i = 0; i < s.Length; i++)
        {
            char c = s[i];
            if (c == '_' || c == ' ' || c == '-') { if (cur.Length > 0) { words.Add(cur.ToString()); cur.Clear(); } continue; }
            bool boundary = cur.Length > 0 && char.IsUpper(c) &&
                (char.IsLower(s[i - 1]) || char.IsDigit(s[i - 1]) || (i + 1 < s.Length && char.IsLower(s[i + 1]) && char.IsUpper(s[i - 1])));
            if (boundary) { words.Add(cur.ToString()); cur.Clear(); }
            cur.Append(c);
        }
        if (cur.Length > 0) words.Add(cur.ToString());
        return words;
    }

    // Preserve Godot resource/user prefixes rather than using OS path semantics.
    public static string PathJoin(this string instance, string file)
    {
        if (instance.Length == 0) return file;
        if (instance.EndsWith('/') || file.StartsWith('/')) return instance + file;
        return instance + "/" + file;
    }
}
