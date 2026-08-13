using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

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
    private readonly Action<string>? _notify;

    // Per-asset running projector tracking — every stub-click would
    // otherwise stack a fresh process; we focus the existing window
    // instead. Mirrors the Swift GameLauncher's runningDCRProcesses map.
    private readonly Dictionary<string, Process> _running = new(StringComparer.OrdinalIgnoreCase);
    private readonly object _runningLock = new();

    public GameLauncher(string projectorDir, Action<string>? notify = null)
    {
        _projectorDir = projectorDir;
        _notify       = notify;
    }

    /// <summary>
    /// Kill every projector process tracked by this launcher AND every
    /// untracked orphan from a previous run. Called on page-navigate so
    /// the embedded game doesn't outlive its page, on app-close so we
    /// don't leak processes, and at startup to reap orphans from a
    /// previous crash / force-close.
    /// </summary>
    public void TerminateAllProjectors()
    {
        bool hadTracked;
        lock (_runningLock)
        {
            hadTracked = _running.Count > 0;
            foreach (var (_, proc) in _running)
            {
                try { if (!proc.HasExited) { proc.Kill(entireProcessTree: true); } }
                catch { /* race with natural exit — fine */ }
            }
            _running.Clear();
        }

        // Only sweep for untracked survivors when we actually had something
        // running. This is called from NavHandler on EVERY navigation, and the
        // sweep enumerates 12 process names and reads MainModule on each match
        // — all on the WPF UI thread. Skipping it when no projector was ever
        // launched makes ordinary page-to-page navigation free.
        if (hadTracked) ReapOrphanProjectors();
    }

    /// <summary>
    /// Kill projector processes that survived a previous force-close or crash.
    ///
    /// Scoped to executables living inside THIS install directory. The names
    /// swept for ("Projector", "SPR", "PJ12", …) are Adobe's, not ours: a
    /// global kill by name would terminate a copy of Director's Projector.exe
    /// the user is running for entirely unrelated reasons, or another
    /// Flashpoint/preservation tool driving the same Adobe binaries. Checking
    /// MainModule.FileName against our base directory keeps the cleanup
    /// guarantee without reaching outside our own install.
    /// </summary>
    public static void ReapOrphanProjectors()
    {
        string[] names = {
            "PJ12", "PJ1159", "PJ1158", "PJ1103", "PJ11_5",
            "PJ10", "PJ101", "PJ9", "PJ851",
            "Projector", "SPR",
            "flashplayer_32_sa",
        };

        string baseDir;
        try
        {
            baseDir = Path.GetFullPath(AppContext.BaseDirectory)
                          .TrimEnd(Path.DirectorySeparatorChar);
        }
        catch { return; }

        foreach (var n in names)
        {
            Process[] procs;
            try { procs = Process.GetProcessesByName(n); }
            catch { continue; }
            foreach (var p in procs)
            {
                try
                {
                    // MainModule throws for processes we cannot open (other
                    // users, elevated). Anything we cannot positively identify
                    // as ours is left alone.
                    var exePath = p.MainModule?.FileName;
                    if (string.IsNullOrEmpty(exePath)) continue;
                    if (!Path.GetFullPath(exePath).StartsWith(
                            baseDir, StringComparison.OrdinalIgnoreCase))
                        continue;
                    p.Kill(entireProcessTree: true);
                }
                catch { /* permission denied / already gone — skip */ }
                finally { p.Dispose(); }
            }
        }
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
        => Launch(assetUri, mirrorRootDir, screenX: null, screenY: null);

    /// <summary>
    /// Same as Launch but also positions the projector window's top-left
    /// at (screenX, screenY) in physical screen pixels — used by the
    /// flash-bridge.js auto-launch path so the projector spawns over the
    /// embed area instead of wherever Director's default centering lands.
    /// </summary>
    public bool Launch(Uri assetUri, string mirrorRootDir, int? screenX, int? screenY)
    {
        try
        {
            var localPath = ResolveLocal(assetUri, mirrorRootDir);
            if (localPath is null || !File.Exists(localPath))
            {
                // The link target points at a SWF/DCR that's not in the bundled
                // mirror — most likely a piece of content the crawl didn't reach.
                _notify?.Invoke($"Game asset not in archive: {assetUri.AbsolutePath}");
                return false;
            }

            var ext = Path.GetExtension(localPath).ToLowerInvariant();
            return ext switch
            {
                ".swf"      => LaunchFlash(localPath),
                ".dcr"      => LaunchDirector(localPath, screenX, screenY),
                ".dir"      => LaunchDirector(localPath, screenX, screenY),
                ".dxr"      => LaunchDirector(localPath, screenX, screenY),
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
        if (!File.Exists(exe))
        {
            // Silent fail used to surface as "the projector pill does nothing".
            // Tell the user what's actually missing so they can either reinstall
            // or, for devs running dotnet run, hydrate projector-windows\.
            _notify?.Invoke("Flash Player projector not bundled — reinstall the app, or for development, run tools\\fetch-projector-windows.ps1.");
            return false;
        }

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

    private bool LaunchDirector(string dcrPath, int? screenX = null, int? screenY = null)
    {
        if (TryFocusExisting(dcrPath)) return true;

        // We prefer PJ12 (Director 12 player) — same default as the macOS
        // GameLauncher. Fall back to older runtimes. Each PJ folder ships in
        // one of two naming conventions:
        //   • Flashpoint local copy:  Shockwave\PJ12\Projector.exe
        //   • CI build-deps tarball:  Shockwave\PJ12\PJ12.exe (pre-renamed
        //     so multiple projectors can co-exist on a flat PATH)
        // We probe both per PJ version in preference order.
        string[] versions = { "PJ12", "PJ1159", "PJ1158", "PJ1103", "PJ11_5",
                              "PJ10", "PJ101", "PJ9", "PJ851" };
        string? exe = null;
        foreach (var v in versions)
        {
            var a = Path.Combine(_projectorDir, "Shockwave", v, "Projector.exe");
            var b = Path.Combine(_projectorDir, "Shockwave", v, v + ".exe");
            if (File.Exists(a)) { exe = a; break; }
            if (File.Exists(b)) { exe = b; break; }
        }
        if (exe is null)
        {
            _notify?.Invoke("Director (Shockwave) projector not bundled — reinstall the app, or for development, run tools\\fetch-projector-windows.ps1.");
            return false;
        }

        var psi = new ProcessStartInfo
        {
            FileName        = exe,
            Arguments       = "\"" + dcrPath + "\"",
            UseShellExecute = false,
            WorkingDirectory = Path.GetDirectoryName(dcrPath) ?? ".",
        };
        var proc = Process.Start(psi);
        if (proc != null)
        {
            Track(dcrPath, proc);
            if (screenX.HasValue && screenY.HasValue)
            {
                // Fire-and-forget: the projector window won't exist for the
                // first few hundred ms after Process.Start, so we poll for
                // it on a background task and call SetWindowPos when it
                // appears. Matches the Mac shell's one-shot positioning;
                // user is free to drag the window after.
                int pid = proc.Id;
                int x = screenX.Value;
                int y = screenY.Value;
                _ = Task.Run(() => PositionProjectorWindow(pid, x, y));
            }
        }
        return true;
    }

    // ─── one-shot positioning over the embed area ───────────────────────

    /// <summary>
    /// Poll for the projector window owned by <paramref name="pid"/> and
    /// move its top-left to (screenX, screenY). Director's startup logic
    /// re-positions the window from inside its own process for ~200ms, so
    /// we wait until the window settles before placing it — otherwise the
    /// projector immediately yanks itself back to screen-center.
    /// </summary>
    private static async Task PositionProjectorWindow(int pid, int screenX, int screenY)
    {
        // Up to ~3s of polling. Director typically creates its window in
        // 100–800ms; longer-lived polling covers cold-cache projector
        // launches.
        for (int attempt = 0; attempt < 60; attempt++)
        {
            await Task.Delay(50);
            var hwnd = FindMainWindowForPid((uint)pid);
            if (hwnd == IntPtr.Zero) continue;

            // Settle wait: let Director finish its own centering before we
            // place. Without this, the projector's internal re-position
            // happens AFTER ours and visibly snaps the window to center.
            await Task.Delay(200);
            SetWindowPos(hwnd, IntPtr.Zero, screenX, screenY, 0, 0,
                SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
            return;
        }
    }

    private static IntPtr FindMainWindowForPid(uint pid)
    {
        IntPtr found = IntPtr.Zero;
        long bestArea = 0;
        EnumWindows((hwnd, _) =>
        {
            if (!IsWindowVisible(hwnd)) return true;
            GetWindowThreadProcessId(hwnd, out uint windowPid);
            if (windowPid != pid) return true;
            if (!GetWindowRect(hwnd, out RECT r)) return true;
            long w = r.Right - r.Left;
            long h = r.Bottom - r.Top;
            if (w < 100 || h < 80) return true;  // skip toolwindows/tooltips
            // Prefer the largest matching window (the actual projector
            // canvas, not e.g. a hidden splash or invisible message-only).
            long area = w * h;
            if (area > bestArea)
            {
                bestArea = area;
                found = hwnd;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int Left, Top, Right, Bottom; }

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter,
        int X, int Y, int cx, int cy, uint uFlags);

    private const uint SWP_NOSIZE     = 0x0001;
    private const uint SWP_NOZORDER   = 0x0004;
    private const uint SWP_NOACTIVATE = 0x0010;

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
