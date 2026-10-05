# Recon map: Clicky (macOS)

Scope: the features ZOOBIE lacks, to replicate two of them. Screen vision is out of scope by the user's choice (local brain, no "what am I looking at").
For: the user's own daily-driver assistant (ZOOBIE), not a product for sale.
Date: 2026-10-04

## Sources

| # | source | URL | notes |
| --- | --- | --- | --- |
| 1 | README | https://github.com/farzaa/clicky/blob/main/README.md | features, setup, architecture summary (repo at a80fa80, 2026-04-27) |
| 2 | Architecture notes | https://github.com/farzaa/clicky/blob/main/AGENTS.md | design decisions, file purposes |
| 3 | Product Hunt listing | https://hunted.space/product/clicky-2 | pitch and feature list |
| 4 | Website | https://www.heyclicky.com/ | newer, closed-source version |

Clicky's open-source version is MIT-licensed. ZOOBIE's code stays its own.

## Core loop

Hold control+option, ask out loud, release: the buddy next to the cursor answers out loud, with the reply on screen beside the cursor and the pointer flying to whatever it mentions.

## Screens

| ID | screen | route / how to reach | purpose | key components | states seen |
| --- | --- | --- | --- | --- | --- |
| S01 | Menu bar panel | click the menu bar icon | status, push-to-talk hint, model picker, permissions, quit | dark floating panel, picker, buttons | permissions missing, ready |
| S02 | Cursor overlay | always on (or only during a request) | the buddy beside the cursor | blue cursor, reply bubble, waveform, spinner | idle, listening, processing, responding, pointing |

## Flows

```
F01 Ask out loud
    hold control+option -> S02 waveform -> release -> S02 spinner -> S02 reply bubble + voice -> pointer flies (optional) -> fades out
    happy path: 1 key hold
    edge: talk again mid-reply (interrupts), no permission, nothing said
```

## Components

| component | variants | states | used on |
| --- | --- | --- | --- |
| Cursor buddy | shown, transient | idle, listening, processing, responding, pointing | S02 |
| Reply bubble | — | streaming, finished, fading | S02 |
| Waveform | — | live mic level | S02 |

## Gaps against ZOOBIE (beyond screen vision)

1. **Reply next to the cursor.** Clicky shows the reply text and waveform in a bubble beside the cursor. ZOOBIE shows them in the notch; its cursor captions exist but are switched off.
2. **Listen-only event tap for push-to-talk.** Clicky's notes say it detects modifier-only shortcuts more reliably in the background than AppKit global monitors, which ZOOBIE uses.
3. **Curved pointer flight.** Clicky's pointer travels along an arc.

## Out of scope

- Screen vision: screenshots with every question, pointing on any monitor (user's choice).
- Paid cloud services: transcription and voice (user wants free and local).
- Analytics and the feedback button (personal app).

## Size

S: two small features on an existing app. Parity today: 86.4 / 100, all 7 must-haves done (`parity.py replica/features.csv`).
