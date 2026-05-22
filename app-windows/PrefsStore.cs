using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace Summer2008;

/// <summary>
/// Tiny JSON-backed key/value store for runtime preferences (currently
/// the volume slider state, set from volume-control.js via fetch() to
/// agd://runtime/__prefs__/&lt;key&gt;).
///
/// Equivalent to the Swift PrefsStore — file lives at
/// %LOCALAPPDATA%\Summer 2008\prefs.json.
/// </summary>
public sealed class PrefsStore
{
    private readonly string _file;
    private readonly object _lock = new();
    private Dictionary<string, string> _data;

    public PrefsStore(string filePath)
    {
        _file = filePath;
        _data = Load();
    }

    public string? Get(string key)
    {
        lock (_lock)
        {
            return _data.TryGetValue(key, out var v) ? v : null;
        }
    }

    public void Set(string key, string value)
    {
        lock (_lock)
        {
            _data[key] = value;
            Save();
        }
    }

    public void Delete(string key)
    {
        lock (_lock)
        {
            if (_data.Remove(key)) Save();
        }
    }

    private Dictionary<string, string> Load()
    {
        try
        {
            if (!File.Exists(_file)) return new Dictionary<string, string>();
            var json = File.ReadAllText(_file);
            return JsonSerializer.Deserialize<Dictionary<string, string>>(json)
                   ?? new Dictionary<string, string>();
        }
        catch
        {
            // Corrupted prefs file shouldn't brick the app — start fresh.
            return new Dictionary<string, string>();
        }
    }

    private void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_file) ?? ".");
            var json = JsonSerializer.Serialize(_data, new JsonSerializerOptions
            {
                WriteIndented = false,
            });
            // Atomic write: temp file → rename. Saves us from half-written
            // state if the user closes the lid mid-save.
            var tmp = _file + ".tmp";
            File.WriteAllText(tmp, json);
            File.Move(tmp, _file, overwrite: true);
        }
        catch { /* best effort — user can re-tune the slider */ }
    }
}
