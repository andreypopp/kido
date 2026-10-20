# Plan: a Core ML question extractor

Status: not started. Date: 2026-10-20. Branch `kido-app-questions`, from
`kido-app` 0.29.1. This plan replaces `plans/paragraph-coreml.md` on
`kido-app-paragraphs` (last commit 85ed85e5). The advisor owns this file.

## Contract

The input is plain text. Its lines are the screen's logical lines. pi
and Claude Code word-wrap their own output at the pane width, so tmux
has no wrapped flag for them and a paragraph or list item spans several
lines with the TUI's own breaks and indents (pi: a hanging indent for
list items; Claude Code: `⏺ ` on the first row and a 2-space gutter).
A question substring contains those row breaks. The output is every
question in the text, in text order:

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
  0.68 option exact F1 on the real eval part in the first attempt).
- Model storage for production is decided later. Until then the model is
  a local build output.
- Cumulative DeepSeek spend cap: $50. The first attempt spent $26.21 (the
  ledger `usage.jsonl` agrees), so this plan has $23.79. Ask the user
  before more.
- A smoke run may make a small number of paid DeepSeek calls (a few
  texts) to check the prompt, the schema and the validator end to end.
  Full runs (the relabel, the eval labelling with several samples,
  training) wait for the code review and its fixes. Each smoke run
  records its spend in the same ledger and counts against the cap.
- Decided by the top-level session on 2026-10-20, to confirm with the
  user: open questions with no finite answer are questions with
  `options: []` (contract unchanged); the labeller records a per-question
  `kind` (`choice`, `yes_no` or `open`) in the label data only, never in
  the CLI output, and the eval reports its metrics with and without
  `open` questions. The eval uses 3 samples on real texts (500, cut to
  400 after the phase 1 cost measure); the $50 cap stays; if a full run
  would exceed the remainder, the manager cuts the run size, not the
  cap.
- Role models. Implementers: `claude-bridge/claude-sonnet-5-5`. Managers:
  `claude-bridge/claude-opus-5-5`. Simplify reviewers: a mix of
  `claude-bridge/claude-opus-5-5` and `openai-codex/gpt-6-astra`.
  Correctness and results reviewers: `openai-codex/gpt-6-astra`. Advisor:
  `claude-bridge/claude-fable-5-1`. DeepSeek is only the labeller API.

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
- The tool-call eval part shared sessions with train (19 of 21 examples).
  Freeze the eval sessions before any labelling, for every part.
- Most inline option errors were at the start of the option (14 of 20
  boundary errors were 6 or more characters off). The prompt needs a
  start rule for inline options.
- Multi-question texts are rare in real data: 1.7% of the old contexts
  had two or more logical lines that end with `?`. Without oversampling,
  an eval cannot measure merges.
- A per-phase manager process with reviewers found real defects each time
  (leakage, redaction gaps, spend overshoot). Keep it.

Measured facts that still hold (first attempt, M5 Max): Ettin-32m trains at
about 32,000 tokens/s on MPS (753 s for 10 epochs over 11,668 examples);
the best sweep point was lr 5e-5 at 10 epochs, still rising; fused AdamW
and batch 32 were the untried speedups. Core ML: one fixed-shape function
per length in one multifunction package (`EnumeratedShapes` puts every op
on the CPU); fp16 keeps the logits (argmax agreement 0.999998); default
`.cpuAndGPU` (2.4 ms at 1,024 tokens, about 250 ms load); the Neural
Engine is slower and loads in 1.5 to 3.6 s; conversion is not
byte-deterministic. The Swift tokenizer (swift-transformers 1.3.5) matches
Hugging Face offsets only with the NFC position mapping.

## Design

1. **Segments.** One splitter cuts the text into segments: sentences, and
   each list item as one segment. The rows of one paragraph or list item
   are one unit: a row break is not a segment boundary, and a sentence
   can span rows. A blank line is its own segment. The splitter sees
   only screen text. Both TUIs remove inline backticks. pi keeps the
   ``` fence rows (with a 2-space code indent) and `### ` headings;
   Claude Code removes fences and heading prefixes. The unit rule is
   layout: a unit is a run of non-blank rows with one continuation
   indent; a blank row, a list marker or a row whose indent differs from
   the unit's continuation indent starts a new unit. In pi a fence row is
   also a unit boundary, and the rows between fences are code, one
   segment per row. In Claude Code code is recognised only by layout: an
   indented block with a blank row before it is its own units, one
   segment per row. In both, code never joins the question after it.
   Inside a
   unit, a sentence ends at `.`, `?` or `!` followed by a space or the
   row end, when the next character is a capital letter or a digit and
   the word before the mark has two or more letters. This keeps paths,
   versions (`v1.2`), `e.g.`, `a.` and URLs in one segment. An inline
   code span that looks like a sentence end (`a. B`) can still split;
   that is a known limit, and the phase 1 boundary measure counts it.
   No marker that is not on the screen enters the text. This plan
   implements the splitter in Python with a JSON file of test cases; the
   app plan ports it to Swift against the same file.
2. **Questions.** An encoder (Ettin-32m, as before) reads the whole text.
   A head tags the first token of each segment `B-Q`, `I-Q` or `O`; the
   loss ignores every other token. A question is a `B-Q` segment and the
   `I-Q` segments after it, its list items and blank lines inside it
   included. The question's substring runs from the first character of
   its first segment after that segment's indent and turn marker (`⏺ `)
   to the last non-space character of its last segment. List markers of
   option rows inside it stay. Gold labels, predictions and every metric
   use this one range rule. A question whose text comes
   after its options ("Two ways: 1. A 2. B. Which one?") starts at the
   first segment that belongs to it.

   Fallback if the spike rejects segments: tag every token (`B-Q` on the
   first token of a question, `I-Q` on the rest), and keep the splitter
   only for the labeller's view. The spike's measure decides (phase 1).
3. **Options.** A second pass reads the text of one question only and tags
   option spans in it (`B-OPT`, `I-OPT`, `O`). The input is tens of
   tokens. Phase 3 compares two models against one encoder trained
   jointly on both tasks, 3 seeds each, and picks by dev (phase 1 showed
   no gap outside seed noise). Training inputs are the gold questions,
   plus a share (about 20%) of gold questions with one segment added or
   removed at either end, so the pass is robust to a boundary error of
   the first pass.
4. **Length and chunks.** The model reads up to 1,024 tokens in one call.
   Chunking is a common case: phase 1 measured that 7.2% of the texts
   with a `?` exceed 1,024 tokens (p90 867, p99 2,390). Phase 4 measures
   a 2,048 shape against chunking at 1,024. Longer text is cut into
   chunks of 1,024 tokens that overlap by 512, cut at paragraph
   boundaries. A question that touches a chunk edge is dropped in that
   chunk; each question is kept from the chunk where it is farthest from
   an edge, and duplicates by character range are removed. Training
   examples are chunks cut the same way, with random start points at
   paragraph boundaries; about 10% of the starts are inside a gold
   question, and the cut question's remaining segments are then `O`. No
   small sliding window: a question with its list, or a question after
   its options, does not fit in a few segments.

## Data

- **Unit:** one rendered assistant message, or one chunk of a long one.
  One text is one example, with one label. No hover variants.
- **Sources:** pi sessions (`~/.pi/agent/sessions`) and Claude Code
  transcripts (`~/.claude/projects`). The `AskUserQuestion` calls give
  exact labels, but there are only about 16 calls (26 questions, 21 texts
  in the first attempt). They are an eval part, not a data source of any
  size.
- **Selection:** a text is a positive candidate when a segment outside
  code contains `?`; the rest are negative candidates. DeepSeek labels
  only positive candidates. A negative candidate gets an empty label
  without a call, except a random sample of 150 of them, labelled to
  measure the share of questions without a `?`: above 2%, report it and
  decide then. Every positive candidate with two or more `?` segments
  that the scan finds is taken, then the rest, up to the budget below.
- **Renderer check first:** compare the lines of one real pi question
  and one real Claude Code question, read from the app, with the
  renderer's lines for the same transcript turn at the same width. The
  pass rule: the same text, the same row breaks and indents, the same
  list markers, the same blank lines. Fix the renderer if they differ.
  The renderer keeps word wrap at a random width (about 60 to 220
  columns) with cell widths, and copies each TUI's layout by source (pi's
  hanging indent; Claude Code's `⏺ ` and gutter). The synthetic
  templates use the same layouts. This is a check, not a data source.
- **Labeller view:** the labeller sees the text as numbered segments, one
  per line, blank lines kept as numbered empty lines. The index is the
  only reliable way to get a boundary from the model; a copied substring
  of a long question fails too often.
- **Labels:** a list of questions, each with `first` and `last` segment
  indexes, the first three words of its first segment (an off-by-one
  check), and its options as exact substrings. The prompt defines, with
  one example each:
  - A numbered list of questions against one question with numbered
    options.
  - A question of more than one sentence ("I see two ways. Which one?").
  - A question after its options.
  - Inline options and their start rule: the option is the noun phrase
    after "or"/the list word, without the verb that the options share
    ("update the docs or keep the change?" gives "update the docs" and
    "keep the change").
  - A yes/no question gets `[]`. "y/n", "yes or no" and the like are not
    options.
  - Not a question: a rhetorical question, a question the agent answers
    itself, a question quoted from the user, a question in code or a
    log.
  - An open question with no finite answer ("What should the name be?")
    is a question with `[]` and `kind: open`. Every question carries a
    `kind`: `choice` (it has options), `yes_no` or `open`. The validator
    checks that `choice` has options and the other kinds have none.
  - Option text: no list marker, no trailing full stop, inner punctuation
    kept, at least 3 characters, no duplicates.

  The validator checks: indexes in range, `first <= last`, the first
  segment is not blank and its first words match, no overlap, each option
  inside its question exactly once. A rejected label goes back once with
  the reason, as before, then is dropped and counted.
- **Synthetic:** texts with 0 to 4 questions: in one paragraph, in
  adjacent paragraphs, as a numbered list of questions, a question after
  its options, inline options and list options, with the TUIs' markers;
  negatives (prose, code, logs, tables, numbered steps, a user's question
  above the answer). Fillers come from train sessions only. The old
  generator's first generation was half near duplicates; measure the
  near-duplicate rate after generation and keep it under 10%.
- **Split and eval, frozen before labelling.** Start from the first
  attempt's `session-plan.json` (in `app/ml/data-paragraphs/`): keep its
  eval sessions as eval, and move every session with an `AskUserQuestion`
  call to eval. Then the baseline's training sessions are not in the
  eval, and the eval is session-held-out for every part. Parts:
  - `AskUserQuestion`: exact labels from the call. About 21 texts; report
    it, never decide on it alone.
  - Real: v4-pro, 3 samples at temperature 1 in thinking mode; a text is
    kept when at least 2 samples agree after validation and gets that
    label. Report the drop rate and the unanimous subset separately.
    At least 100 of the real eval texts have two or more `?` paragraphs,
    so the merge metric has power. Report the drop rate on that subset:
    if it is much higher than on the rest, the filter hides the hard
    cases and the report must say so.
  - Held-out synthetic templates.
- **Dev:** from train sessions, with at least 100 option spans and at
  least 50 multi-question texts, real or synthetic in separate counts.
- **Check by eye:** before training, the top-level session reads about 50
  labelled texts with more than one question.
- **Spend.** Whole messages are about twice as long as the old contexts
  (p50 1,513 against 797 characters for texts with a `?`). The old recipe
  (600 eval texts × 5 samples, 2,100 train texts × 1 sample) cost $21.78
  and would cost about $30 to $40 now; it does not fit in $23.79. The
  phase 1 smoke (5 texts, v4-pro thinking) measured $0.013 to $0.03 per
  text, a mean of 7,750 reasoning tokens per call. One runaway text
  (finish `length` 3 times, 16,384 reasoning tokens each, $0.098) was
  61% of the smoke spend; the good texts cost $0.0078 each with at most
  5,493 completion tokens. Thus a stop on `length` is dropped and
  counted, never resampled, and `max_tokens` is 10,000 to 12,000. The
  ledger is at $26.37, remainder $23.63. At $0.02 per
  text, 2,100 train texts × 1 sample is about $42 and 500 eval texts × 3
  samples about $30: thinking mode does not fit. Phase 1 compares cheaper
  labeller settings on the spike's 100 texts (see "Phases"). Phase 2
  picks the labeller setting and the run sizes from that comparison so
  the whole phase fits the remainder, and the manager cuts the run size
  if a computed full-run cost exceeds it. Phase 1 decided: thinking mode
  stays at $0.0068 per text (thinking off was $0.0008 but dropped 19%
  and agreed only 62%). The ledger is at $27.13, remainder $22.87. Order
  of the phase 2 runs: the eval first, 400 real texts × 3 samples (about
  $8.2), then the 150 negative sample, then train with what is left
  minus a $2 reserve.

## Metrics

All per eval part, mean ± SD over 3 seeds, on the multi-question subset
of the real part separately, and with and without `open` questions:

- Question span F1, exact segment boundaries. Also a lenient F1 (one
  segment off at either end), reported only to explain errors.
- Questions per text, exact. Merges (one predicted span covers two gold
  questions) and splits (two predicted spans inside one gold question)
  counted separately.
- Option exact F1 inside the gold question (the option pass alone) and
  end to end (inside a found question).
- Whole-output exact match per text: the predicted list equals the gold
  list. This is the contract.
- Question false-positive rate on texts without a question: under 2%.

A baseline: the first attempt's checkpoint
(`app/ml/data-paragraphs/output/phase2-nobold-s0`), run on the text in
its numbered-line format without a `>` marker, its units made by the old
run rule, each unit split at every segment that ends with `?` and is in a
`question` line. A new script `baseline.py` holds the minimum needed to
run it; it is deleted after phase 3. The new model must beat it on every
metric above.

The eval runs through the same code path as the CLI: gold labels become
the contract's JSON, and the comparison is on character ranges.

## CLI

`uv run extract [FILE]` reads plain text from FILE or stdin and prints the
contract's JSON. `--ranges` adds character ranges in the input.
`--backend torch|coreml`, `--compute cpu|gpu|ane|all`, `--bench N` as in
the first attempt.

## What moves from `kido-app-paragraphs`

Taken from `app/ml/` at 85ed85e5 with their tests, in the phase that first
uses them, and changed only where the new contract needs it:

- Transcript reading for pi and Claude Code, and the markdown renderer
  with wrap and cell widths (`render.py`, without context cutting, hover
  and variants). Phase 1.
- Redaction (`redact.py`) and its tests, unchanged. Phase 1.
- The DeepSeek client from `label.py`: the spend ledger and cap with
  reserve and settle, the response cache keyed on the request body,
  cancel on interrupt. Resampling on length is not moved: a stop on
  `length` is dropped and counted (see "Spend"). The prompt and schema
  are new. Phase 1 (the spike labels 100 texts).
- The session split with union-find over sessions and families, and
  MinHash dedup (`split.py`). Phase 2.
- The training loop on MPS (`train.py`), seeds and runner (`runner.py`,
  `train_seeds.py`, `aggregate.py`). Phase 3.
- The Core ML conversion with fixed shapes and `MLComputePlan`
  (`convert.py`), parity and benchmark (`parity.py`, `bench.py`), and the
  Swift tokenizer offset check (`swift_offsets.py`, `swift-offsets/`).
  Phase 4.
- `pyproject.toml`, `uv.lock` and the `.gitignore` entries. Phase 1.

Not moved: the line classes and the run rule (`validate.py`), the context
cut around a hover, the hover variants, the old synthetic templates, the
old eval set, labels and reports, `tagger.py`, Create ML, palettisation.
The app changes and `app/Packages/ParagraphTagger` stay parked on
`kido-app-paragraphs` until this plan's model passes.

The old data is in `app/ml/data-paragraphs/` (gitignored): the spend
ledger `usage.jsonl`, `session-plan.json`, the old checkpoint for the
baseline, and the downloaded Ettin weights. The new pipeline reads the
ledger for the cap, the session plan for the split and the weights to skip
a download; it uses no old label, context or cache. New data goes to
`app/ml/data/`, gitignored; git holds only the manifest (counts, hashes,
settings, spend).

## Workflow

Each phase has one manager (see "Role models" under "Decisions"). Code
review comes before any expensive run (training, a full DeepSeek run, a
sweep):

1. The implementer writes the code and its tests. It runs the tests and a
   smoke run. A smoke run may make a small number of paid DeepSeek calls
   (a few texts) to check the prompt, the schema and the validator end to
   end. It records its spend in the ledger.
2. The reviewers (four simplify angles and one correctness reviewer)
   review the code before any expensive run.
3. The same implementer applies the findings that the manager accepts.
4. The implementer runs the expensive step: labelling, training, eval.
5. A results reviewer reads the numbers, the error counts and the run
   logs, and checks them against the plan's metrics and the code (for
   example leakage, a metric that cannot see an error, a wrong
   checkpoint, a spend over the estimate). The manager writes the results
   into this plan and reports.

A fix after step 5 that changes the trained model or the labels repeats
steps 2 to 5 for that change only. Every implementer and reviewer may send
advice or a question to `advisor`.

## Phases

1. **Spike.** Move the phase 1 parts. The renderer check. The splitter
   with its test file. The 100-text spike: sample 100 train-session texts
   with a `?`, all multi-`?` texts the sample has included; label them
   with v4-pro (1 sample, about $0.50), with the labels as exact question
   substrings, not segment indexes; measure how many question starts and
   ends fall on a segment boundary. Go if at least 97% do after splitter
   fixes; otherwise the token-level fallback in "Design". Token counts of
   whole messages. The baseline scored on those 100 texts with the new
   metrics. The two-heads-or-two-models choice: train the option head for
   one epoch on the spike's options and report whether a shared encoder
   hurts the question head. The labeller comparison: label the same 100
   texts with v4-pro with thinking disabled, and, if useful, with a lower
   reasoning effort or a shorter `max_tokens`; report for each setting
   the agreement with the thinking-mode labels (question count, question
   boundaries, option sets, each separately), the validation drop rate
   and the cost per text. Deliverable: the numbers, the go/no-go, the
   choices, and the labeller setting and run sizes that fit phase 2 in
   the remainder.
2. **Data.** Schema, prompt, validator, synthetic generator, the frozen
   session plan and eval set, the labelling of all texts with v4-pro, the
   split, the manifest. The check by eye. Deliverable: the labelled set,
   the eval set, the manifest and the spend.
3. **Training and eval.** Both passes; two models against one jointly
   trained encoder, 3 seeds each, picked by dev; a small sweep on dev
   only; 3 seeds; error counts per kind (merge, split, boundary, missed option, spurious
   option, false question, missed question). Deliverable: a checkpoint
   and the report, against the baseline.
4. **Core ML and CLI.** One fixed-shape function per pass (1,024 tokens
   for questions, and a 2,048 function measured against chunking at
   1,024 on the eval texts over 1,024 tokens; the option pass's shape
   from the question token lengths measured in phase 3), parity against
   PyTorch, latency, `uv run extract`. Deliverable: the package and three example commands for the
   user.

App integration follows as a separate plan after phase 4. It ports the
splitter and the chunking to Swift against the shared test file.

## Phase 1 results

Measured on 2026-10-20 by p1-impl, corrected by the results review and
rescored. The splitter is frozen.

- **Segments: go.** The range rule (`segments.trimmed()`) is used
  everywhere. 255 of 258 question boundaries (98.84%) fall on a segment
  boundary, on 96 labelled texts with 129 questions (74.4% before
  tuning). This is an upper bound: the splitter was tuned on the same
  texts; phase 2 re-measures on fresh labels. The fixes: the range rule;
  inside a list item, cut only after `?`. The sentence rule is 2 or more
  letters or digits before the mark, with an exception for dotted
  initials. Known limit: Claude Code code rows without indent and
  without a blank row merge with the next paragraph.
- **Labels.** Thinking mode: 96 of 100 labelled, 4 dropped on length at
  12,000 tokens; kinds `yes_no` 67, `choice` 51, `open` 11; 117 options;
  $0.0068 per text. Thinking off: $0.0008 per text. Of 93 thinking-mode
  questions, 62 (67%) have the same range without thinking, and 87% of
  those the same option set. Thinking mode stays. Drop bias: on
  multi-question texts, thinking dropped 4 of 25 and no-thinking 8 of
  25; on the other texts 0 of 75 and 11 of 75. Thus length drops and the
  eval's agreement filter both hide multi-question cases: phase 2 reports
  the drops on the multi-question subset as a known bias, and may use
  `max_tokens` 16,000 for the eval only if the spend allows.
- **Tokens** (special tokens included; `data/tokens-manifest.jsonl`).
  Population: raw assistant text blocks. All 49,101 blocks: p99 1,102,
  1.2% over 1,024. The 3,618 blocks with a `?` outside code: p50 410,
  p90 856, p99 2,226, 7.05% over 1,024. The 76 spike positives: 5.3%
  over. Phase 2 measures the share again on the labelled texts.
- **Baseline** (the old checkpoint, new metrics, 96 texts, one range
  rule for gold and predictions): question F1 0.372, count exact 75%,
  whole-output exact 37.5%, merges 4, splits 1, option F1 end to end
  0.008, FPR 30% (6 of 20). The first report (F1 0.14, exact 21.9%)
  compared untrimmed gold with trimmed predictions.
- **Two heads against two models.** Rescored on the original gold with
  the plan's windows (coverage 104 of 106 train and 22 of 23 test
  questions, 16 test texts), head lr 1e-3, 3 seeds, question F1 / option
  F1: question only 0.692 / 0.003; control 0.661 / 0.002; sequential
  0.608 / 0.016; joint 0.651 / 0.165; option model alone, 8 epochs,
  0.137. Every gap is within seed noise (SD 0.03 to 0.05). A shared
  encoder with joint training is not shown to hurt. Decision: phase 3
  compares two models against one encoder trained jointly on the full
  data, 3 seeds each on dev, and picks by dev.
- **Spend.** Ledger $27.13, remainder $22.87.

## To confirm with the user

The open-question rule with `kind`, 3 samples on 400 real eval texts
under the unchanged $50 cap, and labelling only texts with a `?` (under
"Decisions" and "Spend").

## Open items

- The option pass's input shape (phase 3 measures question lengths).
- A 2,048 shape against chunking at 1,024 (phase 4 measures).

## Changes from advice

- 2026-10-20, user (via the top-level session): smoke runs may make a few
  paid calls; role models named. Both are under "Decisions".
- 2026-10-20, top-level session: open questions are questions with `[]`
  and a label-only `kind`; eval with and without `open`; 3 samples on
  500 real eval texts; the cap stays and the manager cuts a run that
  would exceed the remainder. Under "Decisions", to confirm with the
  user.
- 2026-10-20, p1-impl's renderer check, decided by the top-level
  session: pi and Claude Code wrap their own output, so the app's lines
  are screen rows. The contract, the splitter (a row break is not a
  boundary) and the renderer check (wrap at a random width, each TUI's
  layout by source) say so.
- 2026-10-20, p1-impl's smoke, decided by the top-level session: thinking
  mode costs $0.013 to $0.03 per text, so the phase 2 recipe does not fit
  the $23.63 remainder. Phase 1 adds a labeller comparison (thinking
  disabled, lower effort or shorter `max_tokens`) on the spike's 100
  texts, scored as agreement with thinking-mode labels and cost per text.
  "Spend" and "Phases" say so.
- 2026-10-20, p1-rev-correct, corrected by p1-impl's capture: both TUIs
  remove inline backticks; pi keeps fence rows and headings, Claude Code
  removes them. "Design" item 1 now defines the unit rule by layout
  (indent and blank rows, plus pi's fence rows) and the sentence rule by
  the characters around the mark, and names the inline-code split as a
  known limit that the boundary measure counts.
- 2026-10-20, p1-rev-efficiency: one runaway text resampled 3 times on
  `length` was 61% of the smoke spend. A stop on `length` is now dropped
  and counted, not resampled, and `max_tokens` is 10,000 to 12,000
  ("Spend", "What moves").
- 2026-10-20, phase 1 results, decided by the top-level session: two
  models; chunking is common (7.2% of `?` texts over 1,024 tokens), so
  phase 4 measures 2,048; thinking mode stays; DeepSeek labels only `?`
  texts plus 150 sampled negatives; eval 400 × 3 first, then train from
  the remainder minus $2 ("Phase 1 results", "Design", "Data",
  "Spend").
- 2026-10-20, p1-results: gold kept the indent and turn marker while
  predictions were trimmed. "Design" item 2 now has one range rule for
  gold, predictions and metrics; the baseline numbers are corrected
  (F1 0.37, exact 37.5%, merges 4); the head test is marked provisional
  and phase 3 may try joint training cheaply; the token share names its
  population.
- 2026-10-20, step C rescoring, decided by the top-level session: the
  head test shows no gap outside seed noise, so phase 3 compares two
  models against one jointly trained encoder and picks by dev; the
  baseline, token and labeller numbers are replaced; length drops and
  the agreement filter hide multi-question texts, recorded as a known
  bias with a 16,000 `max_tokens` option for the eval.
