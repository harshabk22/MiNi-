# Mini Dictate test results

Run: `cd dictate && ./build.sh --no-app && .build/dictatetest --eval --audio --ai`
(`--verbose` shows each miss; `--eval-dir <folder>` scores your own recordings: `clip.caf` + `clip.txt` with the text you
meant; `--engine dictation` uses Apple's DictationTranscriber instead of SpeechTranscriber).

- **exact**: the output is identical to the expected text.
- **word accuracy**: 1 − word error rate against the expected text (punctuation ignored, numbers normalised).
- **layout match**: same number of sentences and list items.
- **speech WER**: what the recognizer heard against what was spoken.

The speech cases use macOS's built-in `say` voices. They show regressions, not how well it hears a real person: use
`--eval-dir` with your own recordings for that.

All numbers: 2026-11-21, macOS 27.2.1, Apple Silicon.

## Formatting (format-cases.tsv, 35 cases, rules + Apple on-device model)

| version | exact | word accuracy | layout match | model used / rejected |
|---|---|---|---|---|
| 0.1 (before) | 32%¹ | 89.5%¹ | 68%¹ | 2 / 0¹ |
| current | 77–80% | 94.6% | 89–91% | 13–14 / 2–3 |

¹ measured on the first 28 cases (the 7 grammar cases were added later).

## Speech (speech-cases.tsv, 12 clips, live streaming path)

| version | speech WER | key release → text |
|---|---|---|
| 0.1 (before) | 5.0% | 95 ms |
| current, SpeechTranscriber (default) | 3.0% | ~110 ms |
| current, DictationTranscriber | 1.5% | ~72 ms |

On these clips both engines made two real word errors each; the WER difference is mostly number formatting
("2nd" vs "second"). Which engine is more accurate for a real voice has to be measured with `--eval-dir`.

Notes:
- The 5.0% → 3.0% gain comes from joining recognizer segments with a space.
- Right after the on-device language model has run, speech WER on the same clips measured 6.7–7.6% in some runs
  (steady 3.0% otherwise). Not yet explained.
- The language model adds about 0.7–1.2 s when it runs; short, clean sentences skip it.
