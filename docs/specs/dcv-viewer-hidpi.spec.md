# SPECIFICATION: Auto-enable DCV Viewer HiDPI (Retina) on launch

- **Status:** draft (2026-07-28).
- **Related:** implements **CL-06** / **MU-15 / §12.9** of the workstation
  [`ec2-cloud-workstation-dcv-multiuser.spec.md`](../../../docs/specs/ec2-cloud-workstation-dcv-multiuser.spec.md)
  (the server half — a per-session scale watcher that renders the desktop at 200% — is separate,
  in the workstation bootstrap). Touches the DCV launch path (F-10, `DCVLauncher`), same area as
  `resilient-dcv-viewer-launch.spec.md`.

## 1. Overview & Problem

On a Retina Mac the DCV Viewer streams at **1x logical** by default, and macOS upscales it 2x — so
the remote desktop looks **soft / blurry**. The native Viewer has a fix (`enable-high-pixel-density`,
default **off**), but it is buried in **GSettings** (`com.nicesoftware.DcvViewer`, GLib keyfile
backend — *not* macOS `defaults`) with no obvious UI, so every colleague would have to find and flip
it by hand on their own Mac. That violates the product's "zero manual steps" goal.

Because `ssm-connect` already writes the `.dcv` file and launches the Viewer, it is the natural place
to set this once, automatically, for everyone. Every M-series Mac is a 2x Retina display
(`NSScreen.main.backingScaleFactor == 2`), so it is deterministic — not per-machine guesswork.

> **Pairing (important):** HiDPI on the client streams at 2x = crisp *but tiny* unless the **server**
> also renders the desktop at 200%. That server half is **MU-15/§12.9** (a mutter scale watcher in
> the bootstrap). This spec is only the client half; the two ship together.

## 2. Goals / Non-Goals

**Goals:** a Retina Mac connects and the desktop is **crisp with no manual action**; respect a user
who has deliberately turned HiDPI off; never break/slow the connect if the setting can't be written.

**Non-Goals:** the server-side 200% scaling (MU-15, bootstrap); non-Retina/1x displays (left as-is);
changing the DCV transport or the `.dcv` connection file format; a UI toggle (can be added later).

## 3. Functional Requirements

| ID | Priority | Requirement | Notes |
|----|----------|-------------|-------|
| HDPI-1 | P0 | **Enable HiDPI before launch.** Before opening the Viewer, ensure `enable-high-pixel-density=true` in the DCV Viewer GSettings keyfile (`~/.config/glib-2.0/settings/keyfile`, group `com/nicesoftware/DcvViewer`) so the Viewer requests the 2x physical resolution. | GLib's default backend on macOS is the keyfile backend; the Viewer reads it at startup. |
| HDPI-2 | P0 | **Only when Retina (2x).** Apply only if the main display's `backingScaleFactor >= 2`. On a 1x display, do nothing. | All M-series = 2x; guards the rare non-Retina external-only case. |
| HDPI-3 | P0 | **Respect an explicit user choice / be idempotent.** Set the key **only when it is absent** (using the default-off). If the key is already present — `true` *or* `false` — leave it untouched (a user who turned it off is not overridden). | Distinguishes "never configured" (absent) from "user decided" (present). |
| HDPI-4 | P0 | **Never block or fail the connect.** Writing the setting is **best-effort**: any error (unreadable/locked keyfile, parse failure) is logged and swallowed; the Viewer launches regardless. | Same posture as the transient `.dcv` file handling (F-10). |
| HDPI-5 | P1 | **Preserve the rest of the keyfile.** Merge into the existing file — other groups/keys (and any DcvViewer keys the user set) are preserved; only the one key is added. | The Viewer owns this file; we co-edit it. |
| HDPI-6 | P2 | **Injectable seam + tests.** A `DCVViewerConfiguring` protocol with a keyfile implementation, unit-testable without touching the real `~/.config` (temp dir), mirroring the existing DCV seams. | Consistent with `DCVViewerLocating`/`DCVConnectionFileStore`. |

## 4. Acceptance Criteria

- **AC-1 (HDPI-1/2/3):** On a 2x display with the key **absent**, launching adds
  `[com/nicesoftware/DcvViewer]` / `enable-high-pixel-density=true` to the keyfile before
  `DCVLauncher.launch`'s `open`. Unit test with a fake scale + temp keyfile.
- **AC-2 (HDPI-3):** With the key **already present** (`true` or `false`), the keyfile is byte-for-byte
  unchanged.
- **AC-3 (HDPI-2):** With `backingScaleFactor == 1`, nothing is written.
- **AC-4 (HDPI-5):** A keyfile with unrelated groups/keys keeps them all; only the one key is inserted
  (parse → set-if-absent → serialize).
- **AC-5 (HDPI-4):** If the keyfile write throws, `launch` still opens the Viewer (assert the open seam
  is called). Unit test with a throwing configurator.

## 5. Design Notes (for the plan step)

- New seam `protocol DCVViewerConfiguring { func ensurePreferredSettings(backingScale: CGFloat) }`
  and `GLibKeyfileDCVViewerConfigurator` (default) writing `~/.config/glib-2.0/settings/keyfile`.
- Keyfile format (INI-ish, GLib): group header `[com/nicesoftware/DcvViewer]`, line
  `enable-high-pixel-density=true` (GVariant boolean literal `true`). Create the file/dirs if absent.
- Call from `DCVLauncher.launch(...)` **before** `opener.open(...)`, passing
  `NSScreen.main?.backingScaleFactor ?? 1`. Inject the configurator like the other seams
  (default in the `init`), so tests pass a temp-dir/fake-scale double.
- Merge algorithm: read lines → if the group is missing, append group + key; if the group exists but
  the key is missing, insert the key under it; if the key exists, no-op (HDPI-3).
- **No live-apply guarantee:** if the Viewer is already running, the new value is read on its next
  launch (each connect launches a fresh Viewer), which is the normal flow — no need to signal a
  running instance.

## 6. Out of Scope / Future

- A per-profile UI toggle to force HiDPI off (HDPI-3 already lets a user set it off in the Viewer and
  we respect it; a first-class toggle is a later nicety).
- Non-2x / fractional client displays (the workstation only offers integer server scales anyway — see
  §12.9); a future enhancement could read the exact `backingScaleFactor` and pass a matching hint.
