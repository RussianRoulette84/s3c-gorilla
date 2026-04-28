# DESIGN — s3c-gorilla

## Style Prompt

Shadow Cut — dark cinematic security. The aesthetic of a film noir title card crossed with a terminal session. Heavy black canvas, sparse stark whites, one toxic-green accent that signals "secured" and one rare blood-red that signals "exposed." Elements emerge from darkness rather than appearing. Slow creeping push-ins, sharp angular type, the pause before the hit. Restraint, not fireworks.

## Colors

- `#0a0a0a` — canvas (deep black, NOT pure #000)
- `#e8e8e8` — primary foreground (raw white, never pure #fff)
- `#3a3a3a` — cold grey (rules, secondary labels)
- `#39FF14` — toxic green accent (secured / encrypted state, signals)
- `#C1121F` — blood red (used once, for "exposed" emphasis)

## Typography

- **Big Shoulders Display 900** — headlines. Sharp, condensed, angular. Noir title-card energy.
- **JetBrains Mono 400/700** — code, paths, status labels, version stamps. Real dev-tool register.

Pairing tension: institutional display weight vs. terminal precision — the product itself crosses that boundary.

## Motion Rules

- `power3.out` and `expo.out` for entrances — confident arrivals, no float
- `power4.in` reserved for the climax zoom
- Vary directions: clip-path reveal, scale-from-shadow, letter-spacing collapse, hairline scaleX
- Each scene holds 3+s — let the reveal breathe before the cut

## Transitions

- Scene 1 → 2: blur crossfade (medium, 0.5s) — "going deeper"
- Scene 2 → 3: zoom through (0.4s) — climactic reveal of the TouchID payoff

## What NOT to Do

- No gradient text, no neon outer-glow halos, no purple/cyan cyberpunk palette
- No bouncy `back.out` or elastic eases — this product is serious, not playful
- No centered floating headlines — anchor everything to a left or right edge with deliberate negative space
- No pure `#000` / `#fff` — always tint slightly toward the accent
