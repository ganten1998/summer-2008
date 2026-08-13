# Why `Summer2008.entitlements` grants what it grants

The rationale lives here rather than as XML comments inside the plist itself.
`codesign` hands the entitlements to AMFI, whose XML unserializer is stricter
than `plutil` and **rejects comments** — a commented plist lints clean with
`plutil -lint` and then fails at signing time with:

```
Failed to parse entitlements: AMFIUnserializeXML: syntax error near line 9
```

which silently produces an unsigned app. Keep the plist comment-free.

## The entitlements

Notarization requires the hardened runtime (`codesign --options runtime`). The
hardened runtime, by default, blocks exactly the things Wine does in order to
work. Without these five exceptions the app builds, signs, notarizes, and then
fails the first time a user clicks a Shockwave game — while working perfectly in
an unsigned dev build. That failure mode is invisible until release, so do not
remove them without testing a *notarized* build.

| Entitlement | Why |
|---|---|
| `com.apple.security.cs.allow-jit` | Wine JITs Windows code and executes it. |
| `com.apple.security.cs.allow-unsigned-executable-memory` | Wine maps W+X pages for the emulated Windows address space; the Director and Flash projectors do the same for their own bytecode. |
| `com.apple.security.cs.allow-dyld-environment-variables` | `GameLauncher` passes `DYLD_FALLBACK_LIBRARY_PATH` so `wineload` resolves the bundled `lib/` dylibs instead of anything on the host. |
| `com.apple.security.cs.disable-library-validation` | The Wine tree ships ~130 third-party dylibs not signed by this Team ID; library validation would refuse to load them. |
| `com.apple.security.automation.apple-events` | Director projector windows are positioned, focused and torn down through the Accessibility APIs — automation of another process. |

## Signing order

`app/build.sh` signs **inside-out**: every nested Mach-O first, then the bundle.
It deliberately does not use `codesign --deep`, which Apple documents as
unsuitable for distribution signing — it applies the same entitlements to every
nested binary, and a `--deep`-signed bundle can pass local verification and
still be rejected by the notary service.
