# First-launch permissions

ClipMouse needs two one-time permissions — both are ordinary macOS toggles, and everything stays on your Mac.

## 1. Open the app anyway

*Skip this step if you installed via Homebrew or built from source.*

macOS checks apps downloaded from the internet, and an app it doesn't recognize is blocked on first launch. That's expected and happens once:

1. Double-click ClipMouse in **Applications** — an alert appears.
2. Open **System Settings → Privacy & Security**.
3. Scroll down and click **Open Anyway**, then confirm.

## 2. Clipboard access

Needed to collect history — without it there is nothing to show in the menu. macOS asks once; the welcome dialog offers to open the right screen:

**System Settings → Privacy & Security → Clipboard** → ClipMouse → **Always Allow**.

## 3. Accessibility

One toggle powers everything ClipMouse does with keyboard and mouse: the ⌘⇧V history hotkey, ⌘⇧B snippets, pasting from the search panel and the middle-button → right-⌘ remap.

**System Settings → Privacy & Security → Accessibility** → enable the ClipMouse toggle.

<img src="assets/permissions-accessibility-en.png" width="640" alt="System Settings → Privacy & Security → Accessibility: enable the ClipMouse toggle">

If ClipMouse is not in the list, click **+**, confirm, and pick ClipMouse in Applications. No restart needed — the app notices the grant within a couple of seconds.

## If something doesn't work

- **The toggle is on, but hotkeys still don't respond.** The permission record went stale — a known macOS quirk. Run this in Terminal, then grant access again:
  ```sh
  tccutil reset Accessibility dev.zeklop.clipmouse
  ```
- **Paste says “Press ⌘V manually”.** A password manager with Secure Keyboard Entry is open — macOS blocks synthetic keystrokes while it runs. This is a security feature, not a bug.
