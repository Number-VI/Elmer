# Elmer

Twelve text snippets, each bound to a global hotkey. Focus any app, press
`Ctrl+Shift+F1` through `Ctrl+Shift+F12`, and the matching snippet types itself
into whatever has focus.

## Running

Double-click `Elmer.cmd`, or:

```
powershell -ExecutionPolicy Bypass -File Elmer.ps1
```

Leave the window open — it has to stay running to listen for the hotkeys.
Minimize it and it keeps working.

## Snippets

Type into the twelve **Snippet** fields and press **Save**. Snippets are also
saved automatically when you close the window, and reloaded on next launch.

Each row also has a **Label** field. It's yours to name the slot with — "work
email", "support sign-off" — so you can tell the rows apart at a glance. Labels
are never typed; they only ever appear in this window.

## Privacy and storage

**Snippets are hidden by default.** They show as dots whenever Elmer starts.
Click the eye (**Show**) in the bottom bar to reveal them, and again to re-hide.
The setting isn't remembered on purpose — Elmer always starts hidden. Labels are
never hidden, which is what makes them useful: you can tell rows apart without
revealing anything.

**Snippets are encrypted at rest.** They live in `snippets.dat` next to the
script, encrypted with Windows DPAPI at `CurrentUser` scope. The key comes from
your Windows account, so only that account on that machine can read it — copy
the file to another machine, or open it as another user, and it's just noise.

Be clear about what that does and doesn't buy you:

- **It protects against**: someone reading the file off the disk, a backup, or a
  synced folder (OneDrive, Dropbox, a git repo) without your Windows account.
- **It does not protect against**: anything already running as you. DPAPI
  unwraps for any process in your session, and while Elmer is running the
  snippets are ordinary strings in memory. Encryption at rest raises the bar for
  a stolen disk, not for malware on your account.
- Elmer is a **snippet expander, not a password manager**. Anything typed into a
  focused window can be read by that window. Use a real password manager for
  passwords.

The old plaintext `snippets.json` is imported automatically on first run, then
deleted. Copies already in a backup or sync history stay plaintext — if it held
anything sensitive, treat it as exposed and rotate it.

The trade-off: `snippets.dat` is no longer hand-editable. To read or change it
outside the app, go through DPAPI with the same entropy:

```powershell
Add-Type -AssemblyName System.Security
$ent = [Text.Encoding]::UTF8.GetBytes('Elmer/snippets/v1')
$blob = [Convert]::FromBase64String((Get-Content .\snippets.dat -Raw).Trim())
[Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect(
    $blob, $ent, [Security.Cryptography.DataProtectionScope]::CurrentUser))
```

Inside, it's the same JSON as before — one entry per slot, plus settings:

```json
{
  "F1": { "note": "work email", "text": "me@example.com" },
  "settings": { "slow": false }
}
```

## Notes

- **Elmer won't type into its own window.** If Elmer has focus when you press a
  shortcut, it says so in the status bar instead. Click into another app first.
- **Empty slots do nothing**, and the status bar tells you which one was empty.
- **If a shortcut is already taken** by another app, that slot fails to register
  and the status bar names it at startup. The other eleven still work.
- Elmer waits for you to release `Ctrl+Shift` before typing. Otherwise the
  snippet gets delivered as shortcuts rather than text (a `Ctrl+O` in the middle
  of your text would open a dialog).
- **Snippets are typed verbatim.** Nothing needs escaping — `+ ^ % ~ ( ) { }
  [ ]` all type as written. Typing goes through `SendInput` with hardware scan
  codes: the same thing a real keyboard sends, so it works in apps that read raw
  keyboard input as well as ordinary text fields.
- **If a snippet types only partway,** the status bar says so. The usual cause is
  the target app running as administrator while Elmer isn't: Windows blocks
  synthetic input from a lower-privilege process. Run Elmer as administrator too.

## Remote consoles (vSphere, RDP, VNC)

These work, with two things to know.

**Tick "Slow"** in the bottom bar if keystrokes go missing. A remote console
relays every keystroke to the guest over the network, and a burst sent at full
speed can overrun it. Slow mode types one key at a time (~12ms apart) — still
far faster than typing by hand. The setting is remembered.

**Characters not on your keyboard layout won't arrive.** Scan codes say *which
key*, not *which character*, so a character only has one if the active layout can
produce it. Anything else falls back to a Unicode packet, which normal apps
accept but remote consoles discard — they have no key to forward. The status bar
counts these when it happens. On a US layout this covers `é`, `£`, `—` and the
like; plain ASCII is always fine.

Relatedly, the guest interprets scan codes using *its own* layout. If the guest's
layout differs from the host's, punctuation can land as the wrong character —
that's inherent to how remote consoles work, not something Elmer can correct.
