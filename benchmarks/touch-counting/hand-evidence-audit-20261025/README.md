# Hand-veto evidence audit, 25 October 2026

Scope: offline audit of saved traces only. No rule, gate or default changed.
Inputs: the 24 October body-gate replay (gate intact and bypass arms, 22 clips),
the V17 corpus replay, the two 24 October takes and the 25 October live recording.
Tool: `scripts/offline-counter-lab.sh` plus `artifacts/hand-veto-experiment-20261025/tools/`.
Raw output: `artifacts/hand-veto-experiment-20261025/evidence-audit.txt`.

## 1. The holding check is blind on every 120 fps clip

`JugglingContactVerifier.handlingEvidence` takes its wrist views from the dense
neighbour frames at indices −6…+3. The holding rule needs a coupled run of at
least 150 ms with 50 ms on each side of the contact. At 120 fps those indices
cover −50…+25 ms, so the rule can never return `held`.

| Accepted touches with a holding record | 869 |
| --- | --- |
| Record spans ≥150 ms | 523 |
| Both wrists confident in ≥4 views | 782 |
| Evaluable (both) | 469 |

Evaluable records by clip: all eleven 120 fps corpus clips 0 of 324; `low` 141 of
175; `walkthrough` 178 of 202; the two takes 12 of 18 and 31 of 31; live 26 of 27.
The 14 October ground-window defect (fixed by `ContactFrameWindow.groundIndices`)
was the same mistake. The buffered frames for a timed −200…+150 ms window already
exist in `ContactObservationStore.frames`; only the selection is wrong.

Fix (not applied): a timed handling window, versioned so old traces replay
unchanged. It needs fresh processing, because saved records lack the views.

## 2. The five wrist-less false counts are not hand cases at all

The four `juggling_second_ball_in_video` events (19.04–20.73 s) and
`normal_juggling_4` 34.24 s have holding records with no wrist landmarks in any
view and only 75 ms of span. Nothing in the hold rule can act on them.

The trajectory inputs explain the two-ball clip: around 19.0 s the counter is
fed a stationary background ball (x 0.91, y 0.41, 0.036 tall) with single-frame
jumps to a second ball 0.34 frame widths away (frame 2293). Those jumps create
the reversals. The frozen inputs carry `pipelineSignature corpus-baseline-timedFootMotionV6`
and were produced on 14 October with `KickLabYOLO26MotionSegmentation`, before
RF-DETR and the `rf-v1` association guard. Every replay since (body gate, V16,
V17, V18 device comparison) reuses these inputs. That is a fair rule comparison,
but these five events are detector/association artifacts of the old inputs and
may not exist under the production detector. They cannot validate any hand rule.

## 3. Exact events a V19 relaxation would newly accept

Relaxing only `handsUncertain`, `insufficientContactViews` and `handsNearBall`
would newly accept 26 events across the 22 clips (list in the raw output):

| Clip set | Valid | Uncertain | Invalid |
| --- | ---: | ---: | ---: |
| 20 labelled corpus clips | 11 | 1 (`normal_juggling_4` 12.458 s) | 0 |
| walkthrough (reviewed added events) | 12 | 1 (1861, 154792.7 s) | 1 (two-hand catch, 144.36 s) |
| latest (19 Oct) | 0 | 0 | 0 |

Caveat that matters: only 12 of the 26 have an evaluable holding record. For the
other 14, "passed the hand and holding vetoes" is not evidence of anything; seven
of the eleven corpus recoveries are on 120 fps clips where the hold check cannot
fire. The hand veto itself (`rejectsHandContact`) ran on all 26 and was negative.

The 30.56 s and 22.8 s misses in the 21:26 take are already recovered in the V16
frozen replay (neighbour recheck and reciprocal rule), so they are not a V19 gain.
The 22.8 s touch remains missed in paced replays.

## 4. Sustained hold versus transient palm hit, kept separate

- Walkthrough catch 144.36 s: wrists present in all 8 views, span −166…+134 ms.
  The hold rule fails only because it requires the wrists to stay within 0.3 ball
  diameters of their contact offset for 50 ms before the candidate; in a catch
  the hands close at impact (right wrist moves 0.41 diameters between −100 ms and
  contact). A tolerance of 0.45 with grip limits 1.25/1.75 marks it held and
  changes none of the other 1,716 accepted touches with wrist evidence
  (`tools/grip_sweep.py`). This is a sustained-hold rule change and needs its own
  versioned flag and device replay before use.
- Live 26.48 s palm hit: left wrist reaches the ball 34 ms after the candidate
  with confidence 0.41 and 0.30. A hold rule cannot address a transient strike.
  Any one-hand rule needs impact-aligned evidence (the recovered +34/+67 ms views)
  and its own regression sweep. Not attempted here.

## What this changes in the plan

1. Correct evidence collection before any gate change: timed handling window,
   then fresh device processing of the corpus to produce evaluable records.
2. Regenerate the corpus inputs with the production detector and association.
   The frozen 14 October inputs predate RF-DETR; the two-ball false counts are
   artifacts of them.
3. Only then re-run the bypass experiment for the three failure categories and
   review each newly accepted event, with a hold check that can actually fire.
4. The hold-rule tolerance change and any palm-hit rule are separate experiments
   with separate flags. V18 stays as measured on device (568/615, false 5 → 3).
