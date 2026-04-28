# DESIGN — s3c-gorilla v3 (3 min, voice-over)

## Style Prompt

The brand's own purple → orange → pink gradient (matches `lib/ywizz/colorize.sh` exactly) on a dark cinematic canvas. Slow, voice-over-paced — every beat holds long enough for the narrator to breathe. The HOW scene is a real terminal recreation paired with the actual macOS Touch ID dialog so the viewer recognizes the system prompt they already know.

## Colors

- `#0a0a0a` canvas (deep black)
- `#e8e8e8` raw white
- `#9b59ff` purple (rgb 155,89,255 — gradient start, matches `colorize.sh`)
- `#ff8c00` orange (rgb 255,140,0 — gradient mid)
- `#ff69b4` pink (rgb 255,105,180 — gradient end)
- `#d787ff` purple accent (256-color C7, matches install.sh status lines)
- `#ff5566` alarm red (used sparingly for "PLAINTEXT" / wiped)

## Typography

- **Big Shoulders Display 900** — display headlines
- **JetBrains Mono 400/700** — terminal, paths, labels (most of the HOW scene)

## Pacing — Voice-Over Friendly

- Scene 1 WHAT: 0–19.5s (~17s narration window)
- Scene 2 WHY: 20–49.5s (~28s narration window)
- Scene 3 HOW: 50–149.5s (~95s narration window, six narrative beats)
- Scene 4 WHAT AGAIN: 150–180s (~28s narration window)

Beat staggers slowed by ~40% vs. the 45s version to leave room for the narrator. No rapid-fire reveals.

## Scene 3 — Six Beats

1. **Beat 1 (51–73s)** First run — `$ env-gorilla …`, SSH GORILLA banner, master password entry
2. **Beat 2 (73–93s)** Touch ID dialog #1 (pair to wrap), fingerprint scans, secrets SE-wrapped
3. **Beat 3 (93–105s)** "5 MINUTES LATER" — time passes
4. **Beat 4 (105–125s)** Subsequent run — only Touch ID #2 (unwrap), fast 0.3s
5. **Beat 5 (125–145s)** User logs out — `/tmp` blobs wiped, SE keys revoked
6. **Beat 6 (145–150s)** Vault locked — master pw required on next login

Touch ID modal is a CSS recreation of the macOS dialog (dark translucent, rounded, app icon top, animated fingerprint, Cancel / Use Password buttons). Drunken bishop is gone.

## Music

None. Reserved for user voice-over.

## Transitions

Blur crossfade (0.5s, `power2.inOut`) between every scene.

## What NOT to Do

- No music, no narration TTS — leave the audio track empty
- No drunken-bishop randomart text
- No tight stagger trains — narrator needs space
- No cyan/teal — the brand is purple/orange/pink
