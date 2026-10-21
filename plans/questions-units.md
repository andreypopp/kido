# Plan: the question extractor, unit by unit

Branch `kido-app-questions`. Code in `app/ml/`. The advisor (`advisor`)
owns this file. `app/ml_old/` is reference code only: read it for the
DeepSeek client (ledger with reservations, response cache, retries, peak
guard), the transcript readers for pi and Claude Code, redaction and the
Core ML conversion. Nothing imports from it. No old data format is read.

## Goal

    cd app/ml && uv run extract [FILE]

reads text (UTF-8, exact bytes; stdin when FILE is absent) and prints:

    {"questions": [{"question": "…", "options": ["…"]}]}

- `question` is an exact substring of the input. The questions are in
  text order.
- Each option is an exact substring inside its question.
- Empty `options` means yes/no or open.
- `--ranges` adds the character offsets in the input.
- The torch backend comes first. A Core ML backend is a later step.

    cd app/ml && uv run label [FILE]

normalises the input, cuts it into units and labels each unit with one
call, with the settings under "Labelling" (`--peak`, `--no-cache`). It
prints each unit line with its questions. On stderr it prints the cost
and the ledger total. This is how the user inspects the labeller.

## Normalise

One function for the markdown of a transcript (training) and for screen
text (inference). It keeps only plain paragraphs and list items, with
their continuation lines. It drops code blocks, block quotes, headings,
tables, horizontal rules, HTML blocks, front matter and footnote
definitions. Inline, it drops images, removes HTML tags, emphasis markers
and inline backticks, and replaces link syntax with the link text.

For screen text it also drops fence blocks, `#` heading rows,
quote-prefix rows, table rows, rule rows and a leading `⏺ ` marker.
Whitespace collapse removes the gutter. Known limit: on Claude Code
screens, headings and code have no markers and pass as text.

A paragraph whose whole text is bold and that contains no `?` is a
pseudo-heading and is skipped in every phase. In training it is
detected from the markdown strong-emphasis span. In the app it is
detected from the terminal cell styles (every cell of the paragraph
bold), so the app skips it too; this is not a known limit. Only the
plain-text CLI `extract` has no styles and cannot apply the rule.

The function returns a character map from the normalised text back to
the input. The same message as markdown, as pi screen text and as
Claude Code screen text gives the same units.

## Units

A paragraph is a run of non-blank lines. A list paragraph (its first
line is a list item) joins the unit before it when that unit's last
line ends with `?` or `:` or is a list item. Joins chain. Inside a unit,
all lines join with single spaces and whitespace collapses: a unit is
one line. List markers stay as written. The same function makes the
units for labelling, training and inference.

A unit counts only when it contains a `?` or matches the decision-word
pattern, one regex, `corpus.DECISION`. The filter applies to labelling,
training, eval and inference: `extract` makes no model call for an
other unit.

## Labelling

- Model `deepseek-flash`, thinking enabled, `reasoning_effort: low`,
  JSON response format.
- The system prompt is `app/ml/unit_prompt.md`, read at run time. Each
  label stores the prefix of its sha256. The user message is
  `Text: <unit>`. The answer schema is the prompt's.
- Validation: the shape; questions in text order, no overlap, each found
  exactly once, in order; `kind` in `choice`, `yes_no`, `open`; `choice`
  has options, the others none; each option has 3 or more characters,
  no edge spaces, no trailing `.`, no list marker, no duplicate, and
  occurs exactly once inside its question. One correction turn carries
  the errors back. A stop on length is dropped and counted.
- Redaction runs before any call. The client refuses an unredacted unit.
- Budget: this pipeline's own ledger has a $30 limit.
- Peak hours (DeepSeek, UTC): Monday to Friday 01:00 to 04:00 and 06:00
  to 10:00. No send within 15 minutes before a peak. A `--peak` flag
  permits a small run in peak.
- The response cache keys on the request body. Runs are resumable.

## Data

- Sources: the assistant text blocks of pi (`~/.pi/agent/sessions`) and
  Claude Code (`~/.claude/projects`) transcripts.
- Split by session: eval 15%, dev 10%, train the rest; seeded; frozen
  once, with digests.
- Units are deduplicated on the unit text. A unit that occurs in two
  splits stays only in eval or dev.
- Labelled sets: every unit that counts (a `?` or a decision-word
  match), in all splits. The other units are not labelled, except for
  one measurement of the word list: 2,000 uniform train other units (1
  sample) and 1,000 eval other units (3 samples). The missed questions
  are read, the pattern is extended, then frozen. The sizes come from a
  dry-run cost estimate.
- Eval: 3 samples per unit; kept when 2 of 3 agree on the canonical
  label, else dropped and counted. Train and dev: 1 sample.
- No synthetic data at first.

## Model

- Encoder `jhu-clsp/ettin-encoder-32m` at a pinned revision.
- Two token taggers with BIO tags: the question model reads the unit;
  the option model reads each question's text.
- Maximum 512 tokens. A longer unit or question is truncated, in
  training and in `extract`, not dropped. Count and report them.
- At decode, an option span drops a trailing `,`, `.`, `?`, `;` or `:`.
- Training: lr 1e-4, 10 epochs, seeds 0, 1 and 2, gradient clipping 1.0.
- Selection on the real dev only: among the seeds with FPR under 2%, the
  best mean of question F1 and end-to-end option F1.

## Evaluation

On the eval split, once, for the selected checkpoint:

- Question F1 with the exact span, end-to-end option F1, option F1
  inside the gold questions, whole-unit exact match. An overlap question
  F1 is a diagnostic beside the exact-span F1.
- Parts: all units; units with 2 or more questions; units with `choice`
  questions.
- FPR on units with a `?` and an empty label, and on units without a
  `?`, each separately.

## Workflow gates

0. Code with ruff at zero warnings, the smoke tests under "Tests" and
   the dry-run report: the unit counts per split (with a `?`, a
   decision-word match, other) and the projected cost of each labelled
   set at off-peak flash prices.
1. Code review before any paid run.
2. A paid smoke of about 10 units.
3. The full run, off-peak.
4. A results review before training.
5. Training, then the eval, then Core ML.

The user approved the run to completion on 2026-10-21, until `uv run
extract` works with the trained model. The manager chooses the
labelling sizes within the $30 limit and passes the gates without a
wait for the user.

## Status

Labelling is done: every `?` unit and every pool unit is labelled.
Ledger $8.78, of which $1.08 is held for killed calls; the runs were in
DeepSeek peak at the user's request. Gate 4 passed: integrity, the eval
agreement replay and leakage are clean; 74 of 90 sampled labels are
correct. Known label noise: lead-ins such as "Still open:" and a leading
`- ` are inconsistently inside question spans. Gate 5, training, has
started.

## Tests

No unit tests. The pipeline has 2 or 3 end-to-end smoke tests that run
the CLIs: `extract` on the fixtures gives valid JSON, exact substrings
and options inside their question; empty input and invalid UTF-8 input
are covered. The smoke tests run in one process: they call `extract`'s
main in-process and load the checkpoint once, so the suite costs the
torch import plus well under 1 s. Ruff runs with zero warnings.

## CLI fixtures

Synthetic texts, with these among them:

- `For the 2,048-token function, which should the CLI ship?` followed by
  the three items `1. Only the 1,024 function, with chunking`, `2. Both
  functions, and the CLI selects by text length` and `3. Only the 2,048
  function`, each on its own line.
- The same question with numbered items and with `-` items that end in
  `.`.
- `I checked the build.`, a blank line, `Which one do you prefer?`.
- `Should I push it now, or wait for CI? Also, do you want the docs
  updated too?`
