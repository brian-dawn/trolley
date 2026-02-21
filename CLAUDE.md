# CLAUDE.md — trolley

## Rules for AI agents

- Never suggest or implement changes to product structures (config formats, manifest schemas, API shapes, user-facing behaviors) unless explicitly requested. Only implement product structures that have been approved by the user.

## What is trolley

trolley is "Electron for terminal apps." It bundles a terminal emulator runtime with a TUI executable so end users double-click an icon and get a terminal app — no terminal installation or configuration needed. The developer ships their TUI binary, trolley wraps it in a native application with controlled fonts, theme, and window size.

## Core concept

```
┌──────────────────────────┐
│  Native window           │
│  (AppKit / GLFW / WinForms) │
│  ┌────────────────────┐  │
│  │ GPU text renderer   │  │
│  │ (Metal / OpenGL)    │  │
│  └────────┬───────────┘  │
│           PTY             │
│  ┌────────┴───────────┐  │
│  │ Bundled TUI binary  │  │
│  │ (any language)      │  │
│  └────────────────────┘  │
└──────────────────────────┘
```

The end user never sees a shell. The TUI binary runs inside a locked-down terminal surface. When the TUI exits, the window closes. No config UI, no shell escape, no escape hatch.

## Architecture decisions

### Terminal engine: libghostty

libghostty is Ghostty's core library. It handles VT parsing, terminal state, PTY management, GPU rendering, font shaping, and input encoding. It already works on macOS, Linux, and Windows. What Ghostty lacks on Windows is only a native GUI shell (apprt) — but we're building our own apprt on every platform anyway. That's the whole point of trolley.

Evidence that the full stack works on Windows:
- `src/termio/Exec.zig` has a `ReadThread.threadMainWindows` code path — ConPTY is implemented
- `src/pty.zig` has Windows PTY support
- The OpenGL renderer is platform-agnostic and was working on Windows via the (now-deleted) GLFW apprt
- FreeType works on Windows for font rasterization, and we bundle our fonts so font discovery is not needed
- There are Windows-specific bug reports (deadlocks on resize, OpenGL issues) — meaning people are running Ghostty on Windows

Platform support status for our use case:

| Layer | macOS | Linux | Windows |
|---|---|---|---|
| VT parsing + state | ✅ | ✅ | ✅ |
| PTY (termio) | ✅ forkpty | ✅ forkpty | ✅ ConPTY |
| OpenGL renderer | ✅ | ✅ | ✅ |
| Metal renderer | ✅ | N/A | N/A |
| Font rasterization | ✅ FreeType/CoreText | ✅ FreeType | ✅ FreeType |
| Font discovery | Not needed — we bundle | Not needed — we bundle | Not needed — we bundle |
| Native GUI (apprt) | We write this (~600-700 lines Swift) | We write this (~500-700 lines Zig+GLFW) | We write this (~600-800 lines F#+WinForms) |

### Why libghostty over alternatives

We evaluated three approaches:

| Approach | Effort | Renderer included | Windows | Maintenance |
|---|---|---|---|---|
| **libghostty** | ~3000 lines across 3 platform wrappers | ✅ best in class | ✅ core works, we write the window | Low — clean dependency boundary |
| Build on `alacritty_terminal` crate | ~6000 lines | ❌ must build own renderer | ✅ | Low — crate dependency |
| Fork Alacritty | ~1500 lines | ✅ | ✅ | High — merge conflicts, upstream drift |

libghostty wins because:
- We don't write a renderer. That's ~4000 lines of hard, bug-prone code (glyph atlas, cell grid, shaders, cursor, selection) that we skip entirely.
- The contract is clean: we provide a GPU surface and forward input events, libghostty does everything else.
- Ghostty's renderer is best-in-class: Metal on macOS, OpenGL on Linux/Windows, SIMD-optimized VT parsing, proper font shaping, ligatures, Kitty graphics protocol.
- The `apprt/embedded.zig` interface is designed for exactly our use case — external consumers that provide a native window.

### How libghostty works

Ghostty's architecture separates terminal emulation from the GUI host via an abstraction called `apprt` (application runtime).

**Our apprt wrapper → libghostty (inputs):**
- Native key/mouse events (we translate platform events to `input.KeyEvent`)
- Window lifecycle (surface created, resized, focused, closed)
- Clipboard data
- A GPU rendering surface (Metal context on macOS, OpenGL context on Linux/Windows)

**libghostty → our apprt wrapper (via `performAction` callbacks):**
- `set_title` — we update the window title
- `copy_to_clipboard`, `open_url` — we handle with platform APIs
- `new_window`, `new_tab`, `new_split` — we ignore these (single surface, kiosk mode)
- Other actions — handle or ignore as appropriate

**What libghostty owns internally:**
- PTY creation and management (forkpty on POSIX, ConPTY on Windows)
- Spawning the child process (our bundled TUI binary)
- I/O thread reading/writing the PTY
- VT sequence parsing and terminal state machine
- Renderer thread drawing to the GPU surface we provided
- Font loading, shaping, and rasterization
- Input encoding (key events → escape sequences written to PTY)

**What we own:**
- Native window creation (one window, one surface)
- Providing a GPU context to libghostty
- Forwarding input events from the native window
- Handling performAction callbacks
- Kiosk behavior: close window when TUI exits, no shell escape
- Manifest parsing and config

Each surface in libghostty spawns its own I/O thread and renderer thread. We only ever create one surface.

### The apprt interface

`apprt` stands for "application runtime." It's Ghostty's abstraction layer for the platform-native host. There are currently two implementations in the Ghostty repo:

- **`apprt/gtk`** — Ghostty's Linux GUI. Zig calling GTK4 C API. We don't use GTK (too heavyweight/slow to launch), but study this for reference on how Ghostty's apprt contract works.
- **`apprt/embedded`** — the C API consumer interface. This is what the macOS Swift app uses, and what we use on macOS.

The deleted `apprt/glfw` was a cross-platform development/testing apprt. It used GLFW for windowing + OpenGL. Our Linux wrapper uses the same approach (Zig + GLFW), so its deleted code is a useful reference for how to provide an OpenGL surface to libghostty.

Zig's `switch` on the action enum is exhaustive by default. If we write our apprt in Zig, missing a `performAction` case is a compile error. This is a strong reason to write the Linux wrapper in Zig.

On macOS, we must use Swift for AppKit, so we consume the C API via `ghostty.h`. The C boundary doesn't give us exhaustiveness — we need to track API changes manually. But the Swift wrapper is small.

On Windows, we use F# + WinForms via P/Invoke through `ghostty.h`. Like macOS, we lose Zig's compile-time exhaustiveness on the C boundary, but F# provides its own exhaustive match expressions on discriminated unions. The Windows wrapper is also small.

### Managing libghostty as a dependency

**Git submodule + build from source.** Ghostty uses Zig's build system. We add the Ghostty repo as a git submodule pinned to a specific commit and build libghostty as part of our build.

```
trolley/
├── deps/
│   └── ghostty/          ← git submodule, pinned commit
├── build.zig             ← builds libghostty, then our wrappers
└── ...
```

For macOS: `build.zig` compiles the Zig core into `libghostty.a`. The Xcode project links against it via `ghostty.h`.

For Linux: our Zig apprt imports libghostty modules directly. Compiles as one Zig compilation unit — no C boundary needed. GLFW is linked as a system library.

For Windows: `build.zig` compiles the Zig core into `libghostty.a` (or `.lib`). The F# WinForms project links against it via P/Invoke through `ghostty.h`. .NET runtime is pre-installed on modern Windows.

This is how Ghostty itself works. The macOS Swift app links against a compiled static library. The Linux GTK app compiles as one unit. OrbStack ships commercially using the same approach. We pin to a specific Ghostty commit and test against it. Updating is bumping the submodule pin.

### Language choices

**Terminal runtime wrappers: Zig + Swift + F#**

Since libghostty is Zig and we're building against it as a submodule:

- **macOS**: Swift (AppKit) calling libghostty via C API (`ghostty.h`). This is exactly what Ghostty does — proven approach. Metal renderer.
- **Linux**: Zig calling GLFW for window + OpenGL context, importing libghostty modules directly (no C boundary). Ghostty's deleted GLFW apprt used this exact approach and is a reference. Zig gives us exhaustive switch on performAction enums — compile-time safety against missing cases.
- **Windows**: F# + WinForms calling libghostty via P/Invoke through `ghostty.h`. WinForms launches fast and is lightweight. F# provides exhaustive match expressions. OpenGL renderer. .NET runtime is pre-installed on modern Windows.

Why these choices:
- macOS requires Swift for AppKit. Non-negotiable.
- Linux uses Zig because it's the same language as libghostty — no FFI boundary, exhaustive enums, single compilation unit. GLFW because it's the thinnest possible window + OpenGL context with no framework overhead. GTK was rejected as too heavyweight and slow to launch.
- Windows uses F# because WinForms is the fastest-launching desktop framework on Windows, F# gives exhaustive matching and functional style, and P/Invoke through the C API is straightforward.

**trolley CLI tool: Rust**

The CLI (`trolley init`, `trolley build`, `trolley dev`) is a separate binary. Rust is the right choice because:
- Best CLI ecosystem: clap, anyhow, serde, indicatif, dialoguer, xshell
- No memory management friction for string-heavy CLI tool code
- Exhaustive match, Option instead of null, Result for errors
- Static linking works trivially

The CLI does not need to share code with the terminal runtime. It reads manifests, invokes `zig build`, and assembles platform bundles.

### CLI dependencies

```toml
[dependencies]
clap = { version = "4", features = ["derive"] }
serde = { version = "1", features = ["derive"] }
toml = "0.8"
anyhow = "1"
indicatif = "0.17"
dialoguer = "0.11"
console = "0.15"
xshell = "0.2"
which = "7"
walkdir = "2"
directories = "5"
```

## Manifest format

```toml
# trolley.toml
[app]
name = "My TUI App"
version = "1.0.0"
icon = "icon.png"

[binary]
linux = "target/release/my-app"
macos = "target/release/my-app"
windows = "target/release/my-app.exe"

[terminal]
font = "JetBrains Mono"
font_size = 14
theme = "builtin:dracula"
columns = 120
rows = 40
resizable = true
```

## What trolley solves vs "just open a terminal"

- **Font bundling** — ships a Nerd Font so icons/box-drawing always work. Eliminates the majority of "it looks broken" bug reports.
- **Theme lock** — developer controls the color scheme. No more "it looks wrong on your terminal."
- **Size control** — fixed or minimum column/row size so layouts don't break.
- **No shell escape** — user can't Ctrl-C out to a shell prompt. TUI exits, window closes.
- **TERM/terminfo** — set correctly, bundled, no guessing.
- **UTF-8 enforced** — don't inherit broken system locale.

## Feature roadmap

Features are prioritized by: (1) parity with running a TUI manually, (2) dependency ordering, (3) impact.

| Priority | Feature | Category | Description | Depends on | v1 |
|---|---|---|---|---|---|
| 1 | Language agnosticism | Developer Experience | TUI can be any language — trolley just runs a binary | | Yes |
| 2 | TERM / terminfo | Terminal Environment | Set correct $TERM and bundle terminfo so TUI doesn't guess its environment | | Yes |
| 3 | Locale / encoding | Terminal Environment | Force UTF-8 — don't inherit the system's possibly broken locale | | Yes |
| 4 | Font bundling | Terminal Environment | Ship a Nerd Font so glyphs and box-drawing always render correctly | | Yes |
| 5 | Theme lock | Terminal Environment | Developer controls the color scheme — end users can't break it | | Yes |
| 6 | Fixed or minimum size | Terminal Environment | Declare minimum or locked columns/rows so TUI layouts don't break | | Yes |
| 7 | No shell escape | Sandboxing & Security | TUI crashes don't drop to a shell prompt — process exits and window closes | | Yes |
| 8 | Manifest | Developer Experience | trolley.toml defining binary paths per platform and terminal config and metadata | | Yes |
| 9 | trolley build | Developer Experience | Produce distributable bundles from the manifest | Manifest | Yes |
| 10 | trolley init | Developer Experience | Interactive scaffolding of manifest and project structure | Manifest | Yes |
| 11 | trolley dev | Developer Experience | Run TUI in wrapper with hot-reload during development | Manifest | Yes |
| 12 | Platform-native bundles | Packaging & Distribution | .app on macOS / .msi or .exe on Windows / .AppImage or .deb or .rpm on Linux | trolley build | Yes |
| 13 | Cross-compilation | Packaging & Distribution | Run trolley build --target windows-x64 from macOS and get an .exe | trolley build | Yes |
| 14 | Logging | Runtime | Wrapper logs to a file for debugging — location and rotation configurable | | Yes |
| 15 | Crash handling | Runtime | Capture last N lines of terminal output before crash — optionally show native error dialog | Logging | Yes |
| 16 | CLI companion | Platform Integration | myapp --version works from an existing terminal — not just as a GUI launch | Platform-native bundles | Yes |
| 17 | Linux .desktop file | Platform Integration | App shows up in Linux app launchers | Platform-native bundles | Yes |
| 18 | macOS Dock icon and open -a | Platform Integration | Behaves like a real macOS app | Platform-native bundles | Yes |
| 19 | Windows Start menu and taskbar pinning | Platform Integration | Behaves like a real Windows app | Platform-native bundles | Yes |
| 20 | Code signing and notarization | Packaging & Distribution | macOS refuses unsigned apps — Windows SmartScreen penalizes them | Platform-native bundles | No |
| 21 | Single-file distribution | Packaging & Distribution | One binary you can scp somewhere — no installer needed | trolley build | No |
| 22 | Environment isolation | Sandboxing & Security | Don't leak user's $PATH / $HOME / shell config into TUI unless explicitly opted in | | No |
| 23 | IPC sideband | Runtime | TUI communicates with wrapper outside terminal stream — set title / file picker / notifications / open URL | | No |
| 24 | Auto-update | Packaging & Distribution | Swap inner TUI binary without reinstalling the whole wrapper | Platform-native bundles, Code signing | No |
| 25 | Filesystem scoping | Sandboxing & Security | TUI binary can only access declared paths — not whole filesystem | Environment isolation | No |
| 26 | Network policy | Sandboxing & Security | Declare and enforce whether TUI needs network access | | No |
| 27 | macOS App Sandbox / Hardened Runtime | Sandboxing & Security | Required for App Store distribution — entitlements declarable in manifest | Code signing, Filesystem scoping | No |
| 28 | Script runtimes | Developer Experience | Optionally bundle Python/Node interpreter for non-compiled TUI apps | Platform-native bundles | No |
| 29 | trolley publish | Developer Experience | Push built bundles to a registry or CDN | trolley build, Platform-native bundles | No |
| 30 | File associations | Platform Integration | .myformat opens in your TUI app | Platform-native bundles | No |
| 31 | URL schemes | Platform Integration | myapp:// deep linking | Platform-native bundles | No |
| 32 | Multiple surfaces | Runtime | TUI app can open multiple windows | | No |

## Project structure (proposed)

```
trolley/
├── deps/
│   └── ghostty/                  # git submodule, pinned commit
├── build.zig                     # builds libghostty + Linux wrapper
├── build.zig.zon                 # Zig dependency manifest
├── src/
│   ├── apprt/                    # our apprt implementations
│   │   ├── common.zig            # shared apprt logic (config from manifest, kiosk behavior)
│   │   └── glfw.zig              # Linux: Zig + GLFW (OpenGL)
│   ├── config.zig                # manifest → libghostty config translation
│   └── main.zig                  # entry point for Linux
├── macos/                        # macOS: Swift + AppKit (Metal)
│   ├── trolley.xcodeproj/
│   └── Sources/
│       ├── AppDelegate.swift
│       ├── SurfaceView.swift     # Metal surface, input forwarding
│       └── Config.swift          # manifest → libghostty config
├── windows/                      # Windows: F# + WinForms (OpenGL)
│   ├── trolley.fsproj
│   └── src/
│       ├── Program.fs            # entry point, WinForms setup
│       ├── SurfaceForm.fs        # OpenGL surface, input forwarding
│       ├── GhosttyInterop.fs     # P/Invoke bindings to ghostty.h
│       └── Config.fs             # manifest → libghostty config
├── cli/                          # trolley CLI (Rust, separate binary)
│   ├── Cargo.toml
│   └── src/
│       ├── main.rs
│       ├── commands/
│       │   ├── init.rs
│       │   ├── build.rs
│       │   └── dev.rs
│       └── manifest.rs           # trolley.toml parsing
├── fonts/                        # bundled Nerd Font
├── themes/                       # built-in color schemes
└── README.md
```

## Estimated effort per platform wrapper

| Platform | Language | Responsibilities | Lines |
|---|---|---|---|
| macOS | Swift | NSApplication + NSWindow, Metal CALayer for libghostty, keyboard/mouse/IME forwarding, performAction handling, clipboard, resize, retina/DPI | 600-700 |
| Linux | Zig | GLFW window + OpenGL context for libghostty, keyboard/mouse forwarding, performAction handling, clipboard via GLFW, resize | 500-700 |
| Windows | F# | WinForms window, OpenGL context via P/Invoke, keyboard/mouse forwarding, performAction handling via ghostty.h, clipboard via WinForms, resize | 600-800 |
| Shared | Zig | libghostty init, config from manifest, surface lifecycle, kiosk logic (close on exit, no shell) | 300-400 |
| **Total runtime** | | | **~2000-2600** |
| trolley CLI | Rust | init, build, dev commands, manifest parsing, bundle assembly, signing invocation | 500-800 |

## Key technical references

**When implementing any wrapper, always check the Ghostty source first.** Don't guess at the libghostty contract — read how Ghostty implements it.

- **Ghostty source**: https://github.com/ghostty-org/ghostty — study `src/apprt/embedded.zig` (the consumer interface), `include/ghostty.h` (C API), and the macOS Swift code in `macos/Sources/`
- **Ghostty's deleted GLFW apprt**: available in Git history (`git log --all -- src/apprt/glfw.zig`). This is the closest reference for our Linux wrapper — it shows exactly how to provide a GLFW window + OpenGL context to libghostty. Study it before writing the Linux wrapper.
- **Ghostty's GTK apprt**: `src/apprt/gtk/` — study for the apprt contract and how Ghostty manages surface lifecycle, input forwarding, and performAction handling on Linux. We don't use GTK but the contract is the same.
- **libghostty cross-platform tracking**: https://github.com/ghostty-org/ghostty/discussions/9411 — confirms libghostty-vt is fully cross-platform; the full libghostty's only Mac-specific aspect is that the C API wasn't exposed for OpenGL rendering (which we can work around)
- **Ghostty Windows support discussion**: https://github.com/ghostty-org/ghostty/discussions/2563 — Mitchell's incremental porting roadmap; the core (PTY, renderer, fonts) already works, only the native GUI apprt is missing
- **libghostty-vt announcement**: https://mitchellh.com/writing/libghostty-is-coming — roadmap for the public library modules
- **Ghostty architecture overview**: https://deepwiki.com/ghostty-org/ghostty — detailed docs on apprt, surface lifecycle, thread model, renderer
- **Mitchell's original architecture talk**: https://mitchellh.com/writing/ghostty-and-useful-zig-patterns — explains the apprt/surface/renderer/termio separation and how Swift consumes libghostty via C API
- **OrbStack**: https://orbstack.dev/ — commercial product already shipping with embedded libghostty, proves the approach works in production
- **Existing community libghostty consumers**: https://github.com/gabydd/wraith, https://github.com/rockorager/haunt — third-party projects building on libghostty

## Design principles

1. **libghostty does the hard work.** We don't write a renderer, VT parser, font shaper, or PTY manager. libghostty handles all of this. Our job is native windows and kiosk behavior.
2. **Subtractive, not additive.** A terminal emulator has dozens of features. trolley uses the minimum subset: one surface, no tabs, no splits, no config UI, no shell. When libghostty sends `performAction(.new_tab)`, we ignore it.
3. **The developer controls the experience.** Fonts, colors, and size are set in the manifest, not by the end user. This is the key differentiator from "just tell users to open a terminal."
4. **Language agnostic.** The TUI binary can be written in anything. trolley doesn't care. It runs an executable on a PTY.
5. **Lightweight and fast to launch.** The wrapper must feel instant — sub-200ms from double-click to first frame. This is why we chose GLFW over GTK on Linux (no framework initialization overhead) and WinForms over WPF/MAUI on Windows. Every platform wrapper should be the thinnest possible bridge between the OS and libghostty. No unnecessary dependencies, no UI frameworks beyond what's needed for a window + GPU context.
6. **Use Ghostty itself as the primary reference.** When implementing any platform wrapper, study the corresponding Ghostty code first. The macOS Swift wrapper should follow `macos/Sources/` patterns. The Linux Zig wrapper should study the deleted `apprt/glfw` code (available in Git history) and `apprt/gtk` for the apprt contract. The Windows wrapper should study how `ghostty.h` is consumed. Ghostty's code is the source of truth for how libghostty expects to be called — don't guess, read the reference implementation.
7. **Zig where it touches libghostty, Swift where Apple requires it, F# for Windows, Rust for the CLI.** Four languages, each used where it's strongest. No unnecessary FFI boundaries — the Linux wrapper is Zig calling libghostty directly with exhaustive compile-time checks.

## Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| libghostty C API is unstable and "messy" by Mitchell's own admission | API breaks on submodule updates | Pin to specific commits. OrbStack ships commercially on this API — it's proven. Track Ghostty releases. |
| Windows support in libghostty core is untested/incomplete | Windows wrapper doesn't work | The core already runs on Windows (ConPTY, OpenGL, FreeType). Community members file Windows bugs. We test early. |
| Zig ecosystem is small | Fewer libraries, less community support | We only use Zig where it's necessary (libghostty interface, GLFW wrapper on Linux). The CLI is Rust, Windows is F#. |
| Four languages in one project | Complexity, onboarding friction | Each language is used where it's strongest and scoped to a small wrapper (~600-800 lines each). The wrappers don't share code across languages. |
| libghostty gets relicensed or becomes incompatible | Can't ship | Current license is MIT. Monitor upstream. Worst case, pin to a known-good commit indefinitely. |
| Ghostty project priorities don't align with ours | Features we need don't land upstream | We're a thin consumer — we need very little from upstream beyond what already exists. Font bundling and kiosk mode are our code, not theirs. |
| GLFW lacks desktop integration on Linux | No native title bar styling, no D-Bus | Acceptable — the entire window is a TUI, users see the content not the chrome. `.desktop` file handles launcher integration. |
| .NET runtime dependency on Windows | Extra install step for some users | .NET is pre-installed on Windows 10+ and modern Windows Server. WinForms is included in the base runtime. |
