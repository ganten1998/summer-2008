using System;
using System.Diagnostics;
using System.IO;

namespace Summer2008;

/// <summary>
/// Hands off SWF and DCR files to bundled standalone projectors.
///
/// Massive simplification vs. macOS: Windows runs Director projectors
/// natively — no Wine layer. Wires up identically to the macOS shell:
/// flash-bridge.js's "Open in Flash Projector" pill creates an
/// agd-launch://&lt;swf-url-or-path&gt; navigation, which NavHandler routes here.
/// </summary>
public sealed class GameLauncher
{
    private readonly string _projectorDir;

    // Per-asset running projector tracking — every stub-click would
    // otherwise stack a fresh process; we focus the existing window
    // instead. Mirrors the Swift GameLauncher's runningDCRProcesses map.
    private readonly Dictionary<string, Process> _running = new(StringComparer.OrdinalIgnoreCase);
    private readonly object _runningLock = new();

    public GameLauncher(string projectorDir)
    {
        _projectorDir = projectorDir;
    }

    private bool TryFocusExisting(string key)
    {
        lock (_runningLock)
        {
            if (!_running.TryGetValue(key, out var proc)) return false;
            if (proc.HasExited) { _running.Remove(key); return false; }
            try
            {
                // SetForegroundWindow only works for our own foreground; for
                // a child process we can poke at the main window handle.
                var hwnd = proc.MainWindowHandle;
                if (hwnd != IntPtr.Zero) NativeMethods.SetForegroundWindow(hwnd);
                return true;
            }
            catch { return true; }
        }
    }

    private void Track(string key, Process proc)
    {
        lock (_runningLock) { _running[key] = proc; }
        proc.EnableRaisingEvents = true;
        proc.Exited += (_, _) =>
        {
            lock (_runningLock)
            {
                if (_running.TryGetValue(key, out var p) && ReferenceEquals(p, proc))
                    _running.Remove(key);
            }
        };
    }

    /// <summary>
    /// Resolve an asset URL (agd:// or a local path) to a local file inside
    /// the bundled mirror, then launch the appropriate projector EXE.
    /// </summary>
    public bool Launch(Uri assetUri, string mirrorRootDir)
    {
        try
        {
            var localPath = ResolveLocal(assetUri, mirrorRootDir);
            if (localPath is null || !File.Exists(localPath))
                return false;

            var ext = Path.GetExtension(localPath).ToLowerInvariant();
            return ext switch
            {
                ".swf"      => LaunchFlash(localPath),
                ".dcr"      => LaunchDirector(localPath),
                ".dir"      => LaunchDirector(localPath),
                ".dxr"      => LaunchDirector(localPath),
                _           => false,
            };
        }
        catch
        {
            return false;
        }
    }

    private bool LaunchFlash(string swfPath)
    {
        if (TryFocusExisting(swfPath)) return true;

        // Bundled standalone Flash Player.
        //   projector\Flash\flashplayer_32_sa.exe
        var exe = Path.Combine(_projectorDir, "Flash", "flashplayer_32_sa.exe");
        if (!File.Exists(exe)) exe = Path.Combine(_projectorDir, "flashplayer_32_sa.exe");
        if (!File.Exists(exe)) return false;

        var psi = new ProcessStartInfo
        {
            FileName        = exe,
            Arguments       = "\"" + swfPath + "\"",
            UseShellExecute = false,
            WorkingDirectory = Path.GetDirectoryName(swfPath) ?? ".",
        };
        var proc = Process.Start(psi);
        if (proc != null) Track(swfPath, proc);
        return true;
    }

    private bool LaunchDirector(string dcrPath)
    {
        if (TryFocusExisting(dcrPath)) return true;

        // We prefer PJ12 (Director 12 player) — same default as the macOS
        // GameLauncher. Fall back to PJ1159 / PJ1158 / older.
        string[] candidates =
        {
            Path.Combine(_projectorDir, "Shockwave", "PJ12", "PJ12.exe"),
            Path.Combine(_projectorDir, "Shockwave", "PJ1159", "PJ1159.exe"),
            Path.Combine(_projectorDir, "Shockwave", "PJ1158", "PJ1158.exe"),
            Path.Combine(_projectorDir, "Shockwave", "PJ11_5", "PJ11_5.exe"),
            Path.Combine(_projectorDir, "Shockwave", "PJ10", "PJ10.exe"),
            Path.Combine(_projectorDir, "Shockwave", "PJ851", "PJ851.exe"),
        };
        var exe = Array.Find(candidates, File.Exists);
        if (exe is null) return false;

        var psi = new ProcessStartInfo
        {
            FileName        = exe,
            Arguments       = "\"" + dcrPath + "\"",
            UseShellExecute = false,
            WorkingDirectory = Path.GetDirectoryName(dcrPath) ?? ".",
        };
        var proc = Process.Start(psi);
        if (proc != null) Track(dcrPath, proc);
        return true;
    }

    /// <summary>P/Invoke for SetForegroundWindow — used to focus an
    /// already-running projector when the user clicks the relaunch pill
    /// a second time.</summary>
    private static class NativeMethods
    {
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hWnd);
    }

    /// <summary>
    /// Translate a request like agd-launch://www.americangirl.com/agcn/kit/game.swf
    /// into a real on-disk file path under Resources\mirror\www.americangirl.com\…
    /// </summary>
    private string? ResolveLocal(Uri uri, string mirrorRootDir)
    {
        if (uri.IsFile) return uri.LocalPath;
        var host = uri.Host;
        var path = uri.AbsolutePath.TrimStart('/').Replace('/', Path.DirectorySeparatorChar);
        var full = Path.Combine(mirrorRootDir, host, path);
        if (File.Exists(full)) return full;

        // Try base name without __query suffix (same fallback as MirrorHandler).
        var dir = Path.GetDirectoryName(full);
        var stem = Path.GetFileName(full);
        if (dir is null || !Directory.Exists(dir) || string.IsNullOrEmpty(stem)) return null;

        foreach (var f in Directory.EnumerateFiles(dir))
        {
            var name = Path.GetFileName(f);
            if (name == stem || name.StartsWith(stem + "__", StringComparison.Ordinal))
                return f;
        }
        return null;
    }
}
