# CLAUDE.md

Guidance for Claude Code, and for any contributor, working in this
repository. [README.md](README.md) has the general overview.

## Project

mac-fsv is a native macOS port of fsv 0.9 (1999), a 3D file system
visualizer. Two constraints:

1. **Stay faithful to the original graphics.** Any visible change to the
   rendering must be justified against fsv 0.9.
2. **Apple frameworks only** (Cocoa, Metal, MetalKit, QuartzCore). No
   third-party dependencies, no Homebrew, no SwiftPM.

The user writes in French. Documentation (README, this file) is in English.
Code and comments are in English, in fsv's style.

## Commands

```bash
make            # build/mac-fsv.app, universal arm64 + x86_64, macOS 14+
make run        # build, then launch
make clean
```

- The Makefile makes every object depend on every header, so editing a
  `.h` rebuilds everything.
- To add a source file, list it in `CORE_SRC`, `COMPAT_C`, `COMPAT_M` or
  `MAC_SRC` in the Makefile.
- There is no Xcode project and no automated test suite. To check a change,
  build it (with no new warnings), then run the app, preferably with a
  `MACFSV_SCRIPT` scenario (see below).

## Architecture

| Directory | Language | Role |
| --- | --- | --- |
| `src/core/` | C | fsv's original code: geometry, camera, animation, colors, scanning, texture-mapped font. |
| `src/compat/` | C, Obj-C | Replacements for GLib (`glib.c`) and OpenGL 1.1 (`minigl.c` + `minigl_metal.m`). |
| `src/mac/` | Obj-C (ARC) | The AppKit interface that replaces GTK+. |
| `tools/mkicon.m` | Obj-C | Builds the iconset from `src/core/xmaps/fsv-icon.xpm`. |
| `resources/` | — | Info.plist, original HTML help, COPYING, AUTHORS. |

### src/core: fsv's code

- Change as little as possible, and keep the original style: tabs,
  `foo( a, b )`, `/* */` comments.
- The core knows nothing about AppKit. It talks to the interface through
  the `gui_*` functions (`gui.h`) and the `window.h`, `dirtree.h`,
  `filelist.h` and `dialog.h` interfaces, all implemented in `src/mac/`.
- Additions specific to mac-fsv:
  - `camera_drag_pan` (`camera.c`);
  - `ogl_unproject` (`ogl.c`);
  - end-of-frame highlight drawing (`geometry_highlight_*`,
    `geometry_draw_highlight`);
  - `viewport_event` (`viewport.c`), which replaces the GTK callbacks.

### src/compat/glib: minimal GLib

- Only what fsv uses: `GList`, `GNode`, `GMemChunk`, `GStringChunk`, and a
  few utilities.
- **Invariant:** the first three fields of `GNode` have the same layout as
  those of `GList`, so that `g_list_sort` can sort a node's children. Do not
  reorder these fields.

### src/compat/minigl: OpenGL 1.1 on Metal

- `GL/gl.h` and `GL/glu.h` declare only the calls fsv uses. If a GL call is
  missing, add it to `minigl.c` rather than working around it in the core.
- `minigl.c` (plain C) holds the state machine, immediate mode, display
  lists and `GL_SELECT` picking (done on the CPU, with homogeneous
  clipping).
- `minigl_metal.m` holds the shaders (compiled at run time from a string),
  frame submission, buffers and textures.
- The interface between the two is `minigl_internal.h`: `MGLState`,
  `MGLDraw`, `MGLFrame` and the `mglb_*` functions.
  - `MGLState` is compared with `memcmp`, so it must have no padding holes.
- Display lists are **flattened**: nested lists are copied in, then grouped
  by state change.
- **Flat shading:** normal and color come from the *first* vertex of each
  triangle (the provoking vertex), read in the shader via `vid - vid % 3`.
- Wide and stippled lines are expanded into quads in the vertex shader.

### src/mac: the AppKit interface

| File | Contents |
| --- | --- |
| `FSVApp.m` | `main`, command-line options, menus, `gui_update`, `FSVLoadRoot`, debug script runner |
| `FSVMainWindow.m` | Main window: split view, directory tree (NSOutlineView), file list (NSTableView), scrollbars |
| `FSVViewport.m` | 3D view (`MTKView`), animation loop, mouse events |
| `FSVDialogs.m` | Context menu, change root, help, Properties sheet |
| `FSVColorSetup.m` | Color setup sheet, with three tabs |
| `FSVXPM.m` | Converts the original XPMs to `NSImage` |

- The window is forced to the Aqua (light) appearance, like the original
  interface.

## Render loop: known pitfalls

These rules came out of fixing real latency problems. Do not change them
without measuring (`MACFSV_DEBUG=1`).

- **Draw only inside `drawInMTKView:`.** `currentDrawable` is valid only
  during `MTKView`'s draw cycle.
  - The `CADisplayLink` tick calls `[self draw]`, which calls
    `drawInMTKView:`, which calls `animation_loop()`.
  - Drawing outside this cycle caused about 2 s of lag between the mouse
    and the screen.
- The `CADisplayLink` comes from `-[NSView displayLinkWithTarget:selector:]`.
  It pauses after 45 ticks without animation, and `requestAnimation`
  (called by `gui_request_animation()`) wakes it up.
- **Keep the default triple buffering.** With `maximumDrawableCount = 2`,
  the main thread waited about 16 ms per frame.
- The counter to watch is frames **presented** (the “screen: N frames
  shown/s” log line), not frames submitted.

## Debugging

- `MACFSV_DEBUG=1` turns on logging, once per second:
  - frames rendered, presented and dropped;
  - latency to the screen;
  - drawable waits;
  - mouse event handling.
- `MACFSV_SCRIPT="cmd:arg;cmd:arg;…"` replays a scenario without the mouse.
  - Commands: `lookat`, `expandall`, `mapv`, `treev`, `wait`, `revolve`,
    `scroll`, `hover`, `pan`, `mark`, `probe`, `snap`, `quit`.
  - They are implemented in `FSVApp.m` and described in the README.
  - While a script runs, the window is raised to `NSStatusWindowLevel`, a
    latency-critical activity keeps App Nap from skewing measurements, and
    timers run at 60 Hz with zero tolerance.
- `MACFSV_SNAPDIR=dir` sets where `snap:name` saves the window capture.

Example:

```bash
MACFSV_DEBUG=1 MACFSV_SCRIPT="expandall:some/dir;wait:4;pan:6,0,1;snap:end;quit" MACFSV_SNAPDIR=/tmp build/mac-fsv.app/Contents/MacOS/mac-fsv ~/some/root
```

**Never inject system events** (CGEvent, AppleScript) for testing: they go
to whatever app the user has in front. Use `MACFSV_SCRIPT` instead.

## Behavior added since fsv 0.9

- **Left-button drag moves the view.**
  - Past an 8 px threshold it is a drag; below it, it is a click, which
    keeps its “fly to node” meaning.
  - The ground point under the pointer stays under the pointer
    (`ogl_unproject`, then `camera_drag_pan`).
  - In TreeV, the move happens in polar coordinates and does not change the
    camera's orientation.
- **The highlight is drawn at the end of the frame**, instead of into the
  front buffer with `glCopyPixels`.

Add any new departure from fsv 0.9 to the README's “Differences from
fsv 0.9” section.

## License

LGPL 2 or later, like fsv. New files carry the same license header as the
existing files in `src/mac/`.
