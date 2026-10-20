# Plan: a Core ML question extractor

Status: not started. Date: 2026-10-20. Branch `kido-app-questions`, from
`kido-app` 0.29.1. This plan replaces `plans/paragraph-coreml.md` on
`kido-app-paragraphs` (last commit 85ed85e5).

## Contract

The input is plain text. The output is every question in the text, in
text order:

    {"questions": [{"question": "…", "options": ["…", "…"]}]}

- `question` is an exact substring of the input: the question with its
  list of options, if it has one.
- Each option is an exact substring of its `question`. An option outside a
  question cannot occur.
- `"options": []` is a yes/no question. The model never writes "yes" or
  "no"; the consumer shows them.
- The output does not depend on a pointer position. The input has no
  hover marker. The app selects the question under the pointer after the
  model runs.
- Text with no question gives `{"questions": []}`.

## Decisions

From the user and from the first attempt:

- Core ML detection only. English only. DeepSeek `deepseek-v4-pro` labels
  the data; no hand labelling. Data comes from local pi and Claude Code
  transcripts only. No pi extension change. No FoundationModels.
- No bold markers in the input: they made options worse (0.52 against
  0.68 option F1 in the first attempt).
- Model storage for production is decided later. Until then the model is
  a local build output.
- Cumulative DeepSeek spend cap: $50. The first attempt spent $26.21, so
  this plan has $23.79. Ask the user before more.

## What the first attempt taught

- One class per logical line, and units made from runs of tagged lines,
  merge questions next to each other. Two questions in one paragraph get
  one class.
- A numbered list of questions has the same form as one question with
  numbered options. The labels must separate the two.
- The hover marker came from the FoundationModels interface, not from a
  need. Each hover variant was a copy of its context, and the unit metric
  measured mostly a selection rule.
- A metric that uses the same grouping rule as the model cannot see a
  merge.
- Train and eval labels from different labellers gave different option
  conventions. One labeller for all splits fixed it.
- A per-phase manager process with reviewers found real defects each time
  (leakage, redaction gaps, spend overshoot). Keep it.

## Design

1. **Segments.** One splitter cuts the text into segments: sentences, and
   each list item as one segment. It keeps paths, versions (`v1.2`),
   `e.g.`, code spans and list items without a full stop in one segment.
   Python and Swift implement the same rules, with shared test cases.
2. **Questions.** An encoder (Ettin-32m, as before) reads the whole text.
   A head tags each segment `B-Q`, `I-Q` or `O`, from the first token of
   the segment. A question is a `B-Q` segment and the `I-Q` segments after
   it, its list items included.
3. **Options.** A second pass reads the text of one question only and tags
   option spans in it (`B-OPT`, `I-OPT`, `O`). The input is tens of tokens.
   The spike decides between one encoder with two heads and two models.
4. **Length.** The model reads the whole text up to 1,024 tokens (2,048 as
   a fallback shape). Longer text is cut into large overlapping chunks at
   paragraph boundaries; each question is kept from the chunk where it is
   farthest from an edge. Training uses chunks cut the same way, with
   random start points. No small sliding window: a question with its list
   or a question after its options does not fit in a few segments.

## Data

- **Unit:** one rendered assistant message, or one chunk of a long one.
  One text is one example, with one label.
- **Sources:** pi sessions (`~/.pi/agent/sessions`) and Claude Code
  transcripts (`~/.claude/projects`), including `AskUserQuestion` calls,
  which give exact labels.
- **Renderer check first:** compare the rows of one real pi question and
  one real Claude Code question in the app with the renderer's rows. Fix
  the renderer if they differ. This is a check, not a data source.
- **Labels:** a list of questions, each with its first and last segment
  and its options as exact substrings. The prompt defines a list of
  questions against a question with numbered options, and a question of
  more than one sentence, with examples. The validator checks: no overlap,
  segment indexes in range, each option inside its question and once in
  it.
- **Synthetic:** contexts with 0 to 4 questions: in one paragraph, in
  adjacent paragraphs, as a numbered list of questions, a question after
  its options, inline options and list options; negatives (prose, code,
  logs, tables, lists without a question).
- **Eval:** frozen before labelling, session-held-out for every part,
  the tool-call part included (the first attempt's defect). Parts:
  `AskUserQuestion` (exact labels), real (v4-pro, 5 samples, kept where
  they agree), held-out synthetic templates.
- **Check by eye:** before training, the top-level session reads about 50
  labelled texts with more than one question.

## Metrics

- Question span F1, exact segment boundaries.
- Questions per text, exact. Merges and splits counted separately.
- Option exact F1 inside the gold question (the option pass alone) and
  end to end (inside a found question).
- Question false-positive rate on texts without a question: under 2%.
- All per eval part, mean ± SD over 3 seeds.
- A baseline: the first attempt's model, split at segment ends, with a new
  question at each segment that ends with `?`. The new model must beat
  it.

## CLI

`uv run extract [FILE]` reads plain text from FILE or stdin and prints the
contract's JSON. `--ranges` adds character ranges in the input.
`--backend torch|coreml`, `--compute cpu|gpu|ane|all`, `--bench N` as in
the first attempt. The eval runs through the same code path as the CLI.

## What moves from `kido-app-paragraphs`

Taken from `app/ml/` at 85ed85e5, with their tests, and changed only
where the new contract needs it:

- Transcript reading for pi and Claude Code, and the markdown renderer
  with wrap and cell widths (`render.py`, without context cutting, hover
  and variants).
- Redaction (`redact.py`) and its tests, unchanged.
- The session split with union-find over sessions and families, and
  MinHash dedup (`split.py`).
- The DeepSeek client from `label.py`: the spend ledger and cap with
  reserve and settle, the response cache keyed on the request body,
  resampling on length, cancel on interrupt. The prompt and schema are
  new.
- The training loop on MPS (`train.py`), seeds and runner (`runner.py`,
  `train_seeds.py`, `aggregate.py`), the Core ML conversion with fixed
  shapes and `MLComputePlan` (`convert.py`), parity and benchmark
  (`parity.py`, `bench.py`), and the Swift tokenizer offset check
  (`swift_offsets.py`, `swift-offsets/`).
- `pyproject.toml`, `uv.lock` and the `.gitignore` entries.

Not moved: the line classes and the run rule (`validate.py`), the context
cut around a hover, the hover variants, the old synthetic templates, the
old eval set, labels and reports, `tagger.py`, Create ML, palettisation.
The app changes and `app/Packages/ParagraphTagger` stay parked on
`kido-app-paragraphs` until this plan's model passes.

The old data is in `app/ml/data-paragraphs/` (gitignored): the spend
ledger `usage.jsonl` and the downloaded Ettin weights. The new pipeline
reads the ledger for the cap and the weights to skip a download; it uses
no old label, context or cache.

## Phases

1. **Move and spike.** Move the parts above. The splitter with its tests,
   and the measure of how often a v4-pro question boundary on 100 sampled
   texts is not a segment boundary. The renderer check. The baseline
   scored on those 100 texts. Deliverable: numbers and a go/no-go on the
   segment design.
2. **Data.** Schema, prompt, validator, synthetic generator, the frozen
   eval set, the relabel of all texts with v4-pro, split. The check by eye.
   Deliverable: the labelled set, eval set and manifest, and the spend.
3. **Training and eval.** Both passes, a small sweep on dev only, 3 seeds,
   error counts per kind (merge, split, boundary, missed option, spurious
   option, false question). Deliverable: a checkpoint and the report.
4. **Core ML and CLI.** Fixed-shape functions for both passes, parity
   against PyTorch, latency, `uv run extract`. Deliverable: the package and
   three example commands for the user.

App integration follows as a separate plan after phase 4.

## Open items

- One encoder with two heads, or two models (phase 1 spike).
- Whether the 2,048 shape is needed, from the token counts of whole
  messages.
