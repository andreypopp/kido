# Plan: a Core ML tagger for Shift paragraphs

Status: phases 0 and 1 done (see "Phase 0 results" and "Phase 1 data");
code in `app/ml/`. Date: 2026-10-20. Updated with the user's
decisions: Core ML detection only, English only, DeepSeek as the labeller, no hand labelling, no pi
extension change, FoundationModels is deleted when the tagger passes.

This plan replaces the generic `FoundationModels` call in
`app/App/ParagraphModel.swift` with a custom Core ML token tagger. The
tagger is the whole analyzer. The task is labelling, not generation.

## Recommendation

1. **Formulation: one BIO token tagger over the whole numbered context.**
   The tagger reads the same text that the prompt holds today: every logical
   line of the context, newlines kept, the hovered lines marked with `>`. It
   emits one tag for each token: `O`, `B-QUESTION`, `I-QUESTION`,
   `B-OPTION`, `I-OPTION`. Everything else is derived in code:
   - A line's class is the majority tag of its tokens.
   - The unit is the line range from the first to the last tagged line,
     snapped outward to paragraphs by the existing `Paragraphs.unit`.
   - `isQuestion` is true when the unit contains the hovered paragraph.
   - An option is a maximal `B-OPTION I-OPTION*` span. Its character range
     comes from the tokenizer's offsets, so the text is exact and the model
     cannot invent an option. Inline options ("update the docs or keep the
     change?") get the same tags as list options.

   One tagger does the work of a line classifier and a span tagger. A separate
   line classifier gives nothing that the majority rule does not.
   Question and option tags do not depend on the hover, so one labelled
   context yields one training example for each paragraph it contains, at no
   labelling cost. Only the derived `isQuestion` changes with the hover.

2. **Model: `jhu-clsp/ettin-encoder-32m`**, a ModernBERT-architecture
   English and code encoder (10 layers, hidden 384, 50,368-token BPE
   vocabulary, 8K context, MIT), fine-tuned for token classification with
   PyTorch on the M5 Max and converted with coremltools 9.
   https://huggingface.co/jhu-clsp/ettin-encoder-32m
   - Size in the bundle: about 64 MB at fp16, about 35 MB with 8-bit
     palettised weights.
   - Expected latency on the M5 Max at 1,024 tokens: tens of milliseconds on
     the GPU. The 100 ms debounce can then shrink, and the shimmer becomes
     rare.
   - If the 32m model does not meet the eval targets, the next step is
     `jhu-clsp/ettin-encoder-150m` (same family, 150M parameters, about
     300 MB at fp16, about 75 MB at 4 bits). Nothing else changes.

3. **The tagger is the only analyzer.** Every format, list or prose, goes
   through it. **FoundationModels is deleted** when the tagger passes the
   eval in phase 5: the `LanguageModelSession` call in `ParagraphModel`, the
   `unavailable` state, its four captions, `testAvailability`, and the
   framework dependency in `project.yml`. The design section and
   `NOTES.md` follow. This is a step of the plan, not an option.

4. **Hardware: the M5 Max with 64 GB is enough.** Fine-tuning a 32M to
   150M encoder needs under 10 GB. Renting a GPU is only useful for sweeps
   over Ettin-150m. Details in "Hardware".

## 1. Model options

| Option | Quality for this task | Size | Latency (M5 Max) | Effort | Verdict |
|---|---|---|---|---|---|
| Create ML `MLWordTagger` + `NLTagger` | Word-level CRF over Apple's embeddings. Sees words, not lines; `NLTagger` tokenises by `.word`, so newlines and list markers vanish unless encoded as pseudo-words. | A few MB (static) to tens of MB (dynamic) | Milliseconds | Lowest: JSON `tokens`/`labels`, trains in minutes, `NLTagger` returns ranges, no tokenizer work. https://developer.apple.com/documentation/createml/creating-a-word-tagger-model | Phase 0 baseline only. Likely too weak for unit boundaries. |
| Ettin-encoder-32m (ModernBERT architecture) | Trained on 2T tokens of English and code, 8K context, modern tokenizer that handles code and box drawing bytes. | 32M params, ~64 MB fp16 | Tens of ms at 1K tokens | Medium: HF `Trainer` for token classification, padded-attention wrapper for conversion, BPE tokenizer in Swift. | **Recommended.** |
| Ettin-encoder-150m | Best accuracy of the family. | 150M params, ~300 MB fp16 | ~3.0 TFLOP/s on the ANE reported for ModernBERT-base at 1,024 tokens: https://github.com/smpanaro/ModernBERT-AppleNeuralEngine | As Ettin-32m | Only if the 32m model fails the eval. |
| DistilBERT / DeBERTa-v3-small | 512-token limit; our context reaches ~2,000 tokens, so the context needs chunking. DeBERTa's disentangled attention converts poorly and runs slowly on MPS. WordPiece splits box drawing into `[UNK]`. | 66M / 44M | Low | Medium | No. |
| Small seq2seq or decoder (Core ML or MLX) | Generation can invent options and line numbers, needs constrained decoding and a long output; hundreds of ms. `FoundationModels` already is this option. | 0.5B+ | 0.5 to 2 s | High | No. |

**Line structure and the hover marker.** The input text keeps the newline
between logical lines; ModernBERT's byte-level BPE gives the newline its own
token. Each line starts with the existing `>` or space marker and its number,
exactly as `Context.prompt` builds it today, so the prompt string stays the
cache key and the test fixtures stay valid. The tagger learns that `>` marks
the hovered paragraph; the derived `isQuestion` does not need it, but the
marker lets the model resolve two questions in one context.

**Sequence length.** 60 lines or 6,000 characters is about 1,500 to 2,500
tokens; TUI chrome and box drawing cost several tokens per glyph. Use
enumerated Core ML shapes of 512, 1,024 and 2,048 tokens. When the context
exceeds 2,048 tokens, drop the outermost context paragraphs first; the hovered
paragraph alone is at most 6,000 characters by `Paragraphs.isTooLong`, so it
always fits. Measure the token count distribution in phase 0.

**Language.** English only, by decision. Ettin is trained on English and
code. Its byte-level tokenizer reads any script, so non-English text does not
break the tagger; it only gets no training and no eval.

## 2. Hardware

**Fine-tuning on the M5 Max (64 GB, 460 or 614 GB/s memory bandwidth,
neural accelerators in each GPU core:
https://www.apple.com/me/macbook-pro/specs/).** PyTorch MPS with Hugging Face
`transformers`, `attn_implementation="sdpa"` (ModernBERT's unpadded
FlashAttention path is CUDA only:
https://huggingface.co/answerdotai/ModernBERT-base/discussions/47), bf16,
batch 16 at 1,024 tokens:

| Model | Examples × epochs | Rough time |
|---|---|---|
| Ettin-32m | 5,000 × 3 | 5 to 10 min |
| Ettin-32m | 30,000 × 3 | 30 to 60 min |
| Ettin-150m | 30,000 × 3 | 3 to 5 h |

These are estimates from reported MPS throughput for BERT-size encoders
(200 to 300 samples/s at 128 tokens for BERT-base:
https://chrwittm.github.io/posts/2024-01-05-running-ml-on-apple-silicon/)
scaled to 1,024 tokens. Phase 0 measures the real number. Memory is under
10 GB for every row. MLX has no token-classification trainer for this
architecture (`mlx-raclate` supports ModernBERT for masked LM, classification
and similarity only: https://www.pitti.io/projects/raclate-mlx), so use
PyTorch.

**When to rent a GPU.** Only for a hyperparameter sweep over Ettin-150m, or
if an MPS operator is missing. One H100 costs about $2.4 to $4 per hour
(RunPod secure/community, Lambda: https://www.runpod.io/pricing,
https://flopper.io/providers/lambda-labs) and fine-tunes Ettin-150m on
30,000 examples in about 20 minutes. A whole evening of sweeps is under $20.
Do not rent for the 32m model.

**Labelling cost.** The labeller is the DeepSeek API, OpenAI-compatible at
`https://api.deepseek.com`, with `response_format: {"type": "json_object"}`
(the prompt must also say "JSON", and `max_tokens` must cover the whole
object: https://api-docs.deepseek.com/api/create-chat-completion/). Current
models and prices (https://api-docs.deepseek.com/quick_start/pricing):

| Model | Version | Input, cache miss | Output | Use |
|---|---|---|---|---|
| `deepseek-flash` | DeepSeek-V4.1-Flash-1017 | $0.15 / $0.30 per M | $0.60 / $1.20 per M | Training labels |
| `deepseek-v4-pro` | DeepSeek-V4-Pro-0813 | $0.66 / $1.32 per M | $1.98 / $3.96 per M | Eval labels, thinking mode |

The first price is off-peak (all times except 01:00 to 04:00 and 06:00 to
10:00 UTC on weekdays), the second is peak. Both models default to thinking
mode and support non-thinking mode. One context is about 1,500 input tokens
and 150 output tokens. Training labels for 20,000 contexts with
`deepseek-flash`, non-thinking, off-peak: about $6. Eval labels for 1,000
contexts with `deepseek-v4-pro`, thinking, 5 samples each: about $15 to $30,
because thinking output is billed. The labelling script runs off-peak by
default.

## 3. Data pipeline

**Sources on this Mac** (counts only; no content is in this plan):

- pi sessions, `~/.pi/agent/sessions`: 334 session directories, 1,985 files,
  1.6 GB. About 19,900 assistant text blocks, about 1,200 of which have a
  question mark in their last 300 characters.
- Claude Code, `~/.claude/projects`: 60 projects, 3,287 `.jsonl` files,
  1.4 GB. About 131,000 assistant entries. 60 `AskUserQuestion` tool calls
  with the fields `question`, `header`, `options`, `multiSelect`.

The pi and Claude Code sessions are the only real sources. There are no
terminal captures.

**Rendering transcripts into terminal text.** A transcript holds markdown.
`render.py` is a simple markdown renderer, not a copy of each TUI. It uses a
CommonMark parser (`markdown-it-py`) and walks its tokens:

- Headings: the heading text on its own line, without `#`.
- Paragraphs: the text, with a blank line after it.
- Lists: the marker kept (`1.`, `-`, `*`), nested items indented by 2
  columns, wrapped rows indented to the item text.
- Code blocks: the code lines verbatim, without the fences, indented by 2
  columns, never wrapped.
- Block quotes: each line with a `│ ` prefix.
- Tables: rows as `| a | b |` text.
- Bold: kept as `**…**` (see "Bold markers" below).
- Other inline markup: `*`, backticks and link syntax removed, link text
  kept.

The renderer hard-wraps at a width sampled from 60 to 220 columns. An
`AskUserQuestion` call is rendered as the question paragraph and a numbered
list of its options, through the same renderer. There is no TUI chrome (turn
markers, boxes, status lines). Wrapped rows are joined again by the same
rule as `Paragraphs.partition`, so the training text is the logical-line
text that the app will send. Context windows are
cut by the app's own rule (2 paragraphs each side, 60 lines, 6,000
characters), re-implemented once in Python with a shared fixture that the
Swift tests also use, so the two cannot drift.

**Bold markers.** Bold is the one style that the terminal keeps as a cell
attribute, and agents often put option labels and headings in bold. The
model text is plain text with `**` around each bold run, on both sides:

- Training: the renderer keeps markdown's strong emphasis as `**…**` and
  removes all other markup.
- App: when it reads rows, the app writes `**` around each run of bold cells.
  It removes the markers again when it maps tag offsets back to cells, so a
  marker never becomes part of a span.

The app does not try to rebuild other markdown (headings, code, fences)
from cells, because that guess is ambiguous and cannot be tested without
captures. Today the app reads only text from Ghostty. The bold attribute per
cell probably needs a small change in the Ghostty fork, next to the
selection-point read of `273b7e72e`. Phase 0 measures whether the markers help
before that change is made.

**Redaction before the send.** The rendered contexts go to DeepSeek. They
are the user's own transcripts and can contain secrets. `redact.py` runs on
every context before `label.py` sends it, and it is on by default:

- Secrets and tokens by pattern: `sk-`, `ghp_`, `xox`, `AKIA`, JWT shapes,
  `Bearer ...`, `password=`/`token=`/`key=` values, long base64 or hex runs.
- Email addresses.
- Paths under the home directory: `/Users/<name>/...` becomes
  `~/...`, and the user name itself is replaced everywhere.
- Each replacement keeps the length class (short, long) and the token class
  (word, number, path), so the line structure and the list markers that the
  labels depend on do not change. The labels refer to line indexes and
  substrings of the redacted text, and the training text is the redacted
  text too, so the two always agree.

The API key comes from the environment variable `DEEPSEEK_API_KEY`, read by
`label.py` at start. It is never in git, in the manifest or in a config
file. A missing key is an error that names the variable.

**Training labels.** `deepseek-flash`, non-thinking, JSON output mode. The
labeller gets one redacted context and returns a strict schema: for each
line index a class (`question`, `option`, `other`), and for inline options a
list of `{line, text}` with the exact substring. `validate.py` rejects a label
whose substring is not found exactly once in its line, whose option line is
not adjacent to the unit, or whose unit is not one contiguous range.
Rejections go back to the labeller once with the reason, then are dropped.
Token tags are then projected from line classes and substrings through the
tokenizer's offsets. The prompt asks for the same rules that the app
enforces: options without list markers, at least 3 characters, no
duplicates.

**Synthetic augmentation**, generated from templates and from labelled
positives: list formats (`1.`, `1)`, `a)`, `-`, `*`, `•`, `❯`, `[ ]`),
inline "A or B?" forms, questions without options, options split by blank
lines, a question in a box, and the hard negatives: plain prose, code,
diffs, logs, tables, stack traces, shell prompts, numbered lists that are not
options (steps, file lists), and a question that the user asked (above the
agent's answer). Negatives should be at least half of the set.

**Dedup and split.** Exact dedup on the normalised context; near-dedup by
MinHash over line shingles. Split by session, never by example, so an eval
context never shares a session with a training context.

**Eval set, labelled without a human.** Three parts, each with a different
source of truth, so that the eval does not only repeat the training
labeller:

1. **Ground truth from tool calls.** The 60 `AskUserQuestion` calls from the
   Claude Code transcripts carry the question and the options as data. The
   renderer draws the box, and the labels come from the call, not from a
   model. This part is exact.
2. **Synthetic with known labels.** Generated positives and negatives whose
   labels are known by construction, from templates that the training
   generator does not use (held-out formats and wordings). This part is
   exact but artificial.
3. **Real contexts, labelled by a stronger model with self-consistency.**
   About 600 real contexts from held-out sessions, half with a question mark,
   half without. `deepseek-v4-pro` in thinking mode labels each one 5 times
   at temperature 1. A context enters the eval only when all 5 samples agree
   after validation; the rest are dropped and counted. The training labeller
   (`deepseek-flash`) never sees these contexts.

Measure on each part and on the union:

- Token F1 per class.
- Option exact-span precision, recall and F1.
- Unit range accuracy: the derived paragraph range equals the labelled one.
- Question false-positive rate on non-question contexts. Target under 2%.
  A false click target is worse than a missed one.
- Latency p50 and p95 for each shape bucket on the M5 Max.

**What this does not prove.** Parts 1 and 2 prove exactness only on formats
that the renderer and the templates know. Part 3 proves agreement with a
stronger model, not with the user: a bias that both DeepSeek models share
(for example, reading every numbered list as options) passes the eval and
is only found in use. Dropping the contexts where the samples disagree
removes the hardest cases from the eval, so the reported numbers are an
upper bound. Phase 5 adds the misses seen in use to the eval set, which is
the only correction for both limits.

**Privacy.** Every rendered or labelled text stays under
`app/ml/data/`, which is gitignored. Git holds only the manifest: counts,
content hashes, the renderer, sampler and redaction configuration and the
seed. What leaves the Mac: the redacted contexts sent to DeepSeek, and
nothing else. DeepSeek's data terms apply to that text.

## 4. Conversion and integration

**Conversion.** coremltools 9.0 (Python 3.13 at most:
https://pypi.org/project/coremltools/). Wrap the fine-tuned model in a
padded-attention module (the single-file pattern of
https://github.com/smpanaro/ModernBERT-AppleNeuralEngine: dense attention
with explicit global and sliding-window masks, RoPE as sin and cos arithmetic),
trace or `torch.export` it, and convert with inputs `input_ids` int32 and
`attention_mask` int32 of enumerated shape `[1, L]`, L in {512, 1024, 2048},
output logits `[1, L, 5]`. Weights fp16. Try `computeUnits = .all` first and
compare the logits against PyTorch with KL divergence on the eval set; the
ANE's fp16 activations overflow on ModernBERT's outlier activations unless the
weights are rotated (QuaRot style, as in that repository). If the ANE degrades
the result, use `.cpuAndGPU` with fp32 compute precision; a 32M model is still
fast on the GPU. Palettise to 8 bits with `ct.optimize.coreml` only if the
bundle size matters.

**Tokenizer in Swift.** `swift-transformers` 1.3.5 (`Tokenizers` module)
loads `tokenizer.json` offline from the bundle with
`AutoTokenizer.from(modelFolder:)` and supports byte-level BPE:
https://github.com/huggingface/swift-transformers/releases. The ModernBERT
`tokenizer.json` is a few MB. Character offsets: the API returns ids and
tokens, not offsets. Byte-level BPE is lossless, so the offsets follow from the
cumulative byte length of each decoded token; phase 0 verifies this on text
with box drawing, emoji and CJK. If it fails, ship the vocabulary and merges
and write a 150-line BPE encoder with offsets. Create ML needs none of this,
which is its one advantage.

**Xcode project.** `app/` is an xcodegen project (`app/project.yml`,
`make project`), not SwiftPM. The local package
`app/Packages/ParagraphTagger` (phase 4) depends on
`https://github.com/huggingface/swift-transformers`; `project.yml` adds it
under `packages:` and as a dependency of the `Kido` target, and adds
`Resources/Models/ParagraphTagger.mlpackage` and the tokenizer folder to the
target's `sources` with `buildPhase: resources` for the tokenizer and the
default phase for the model, so that Xcode's Core ML compiler produces the
`.mlmodelc`. The package's tests have no Xcode build step for the model, so
they compile the `.mlpackage` at run time with `MLModel.compileModel(at:)`.
Where the model binary is stored (Git LFS, a release asset
fetched by a script, or git itself) is decided later. Until phase 4, the
model stays under the gitignored `app/ml/data/output/`.

**Load time and latency.** The compiled model loads in 100 to 300 ms. Load it
on the first Shift press (where `availability()` runs today) in a detached
task, and keep the `MLModel`. A call at 1,024 tokens is expected at 10 to
40 ms on the GPU; the ANE is faster at lower power. The tokenizer runs on a
background actor; the Core ML prediction is synchronous on that actor.

**Analyzer interface.** Phase 4a keeps `ParagraphAnswer` unchanged. A new
`ParagraphTagger` produces `isQuestion`, `options` (exact substrings),
`firstLine` and `lastLine` from its tags, and `ParagraphModel.analyze` calls
it. `Paragraphs.unit` locates each option exactly
on its first branch, and the canned `testAnalyze` closures and every test
keep working with no edit. Phase 4b adds an optional character range for
each option to `ParagraphAnswer`, used by `locate` when present; test
fixtures that omit it still go through the text locator. The locator's fuzzy
branches (case-insensitive, whitespace, marker stripping) are deleted when
the debug log shows them unused.

**Cell width.** Not affected. A span is still a character range in the block
text, and `segments` still maps characters to cells with
`Paragraphs.cellWidth`. The known issue "Paragraph spans can miss by a
column" stays as it is.

**Availability.** A bundled Core ML model is always available. The
`unavailable` state and its four captions exist only for FoundationModels and
are deleted with it in phase 5.

## 5. Where the training code lives

`app/ml/`, Python managed by uv:

    app/ml/pyproject.toml   python 3.12 pinned; torch, transformers,
                            coremltools 9, datasketch, openai (DeepSeek client)
    app/ml/uv.lock
    app/ml/Makefile         data, redact, label, eval-label, split, train,
                            eval, convert, bench
    app/ml/render.py        transcripts to logical-line contexts
    app/ml/redact.py        the redaction pass, with its unit tests
    app/ml/label.py         DeepSeek labelling with the strict schema;
                            --model flash|pro, --samples N, off-peak by default
    app/ml/validate.py      labels to exact spans, rejections with reasons
    app/ml/evalset.py       the three eval parts, agreement filter, counts
    app/ml/split.py         dedup and session-level split
    app/ml/train.py         token classification, seeded, bf16 on MPS
    app/ml/eval.py          the metrics above, per eval part
    app/ml/convert.py       the padded wrapper, enumerated shapes, KL check
    app/ml/bench.py         latency per shape on this Mac
    app/ml/manifest.json    counts, hashes, config and seed; no text
    app/ml/data/            gitignored: renders, labels, splits, checkpoints,
                            output/ with the .mlpackage
    app/ml/fixtures/        the shared context-cutting fixture for Swift and Python
    app/ml/tagger.py        the test CLI (phase 3b)
    app/Packages/ParagraphTagger/
                            SwiftPM package (phase 4): tokenizer, Core ML
                            call, tags to spans

Reproducibility: pinned versions in `uv.lock`, one seed in the manifest,
deterministic sampling from the manifest's hashes, the DeepSeek model
versions recorded in the manifest with each label file. Retrain:

    cd app/ml && uv sync
    export DEEPSEEK_API_KEY=...   # from the user's shell, never in git
    make data            # render; needs the local transcripts
    make redact label    # deepseek-flash, training labels
    make eval-label      # deepseek-v4-pro, 5 samples, agreement filter
    make split train eval
    make convert bench   # writes data/output/ParagraphTagger.mlpackage

The model's content hash goes in the manifest.

## 6. Risks and open items

Risks:

- Tokenizer offsets in Swift are not provided by the library. Phase 0
  verifies the decode-and-accumulate method.
- ANE fp16 outliers can break ModernBERT-family models. The GPU path is the
  safe fallback and is fast enough.
- The MPS path for ModernBERT needs `sdpa` and a recent `transformers`;
  version pins may need trial.
- Real positives are few: about 1,200 pi question turns and 60 Claude Code
  boxes locally. Synthetic data must supply the rest.
- Label noise and shared bias between the two DeepSeek models. The
  validator, the exact eval parts and phase 5's misses bound it; nothing
  removes it.
- Redaction can change a line in a way that changes its label (a redacted
  path that was the option text). The redaction keeps the token class, and
  the label is made on the redacted text, so the training pair stays
  consistent; only the realism drops.
- The simple renderer does not draw TUI chrome (turn markers, the
  `AskUserQuestion` box, status lines), so the real pane text differs from
  the training text. Synthetic examples add some chrome; phase 5's real
  misses show if this matters.
- A 35 to 64 MB binary in the repository or in the release pipeline.

Open items:

1. Where the model binary lives: Git LFS, a release asset fetched by a
   script, or git. Decided before phase 4.
2. DeepSeek's data terms for the redacted contexts. The user accepts them or
   not before phase 1 sends anything.

## Phases

**Phase 0. Feasibility spike. 2 to 3 days.**
Render 300 to 500 contexts from local transcripts, redact
them, and label them with `deepseek-flash`. Train two taggers on the M5 Max:
Create ML `MLWordTagger` and Ettin-32m. Convert Ettin-32m to Core ML with the
padded wrapper and measure latency per shape and the KL against PyTorch on
the GPU and the ANE. Verify Swift tokenizer offsets on hard text. Measure the
token count distribution of real contexts. Train Ettin-32m twice, with and
without bold markers, on the same split, and compare the F1. Check how the
app can read the bold attribute of each cell from Ghostty (existing API or a
fork change, and its size).
Deliverable: a page of numbers (F1 per model, F1 with and without bold
markers, latency, size, token counts, a
training throughput figure) and a go/no-go on the model, on the ANE and on
bold markers.

**Phase 1. Data pipeline. 3 to 5 days.**
`app/ml/` with renderer, redaction with tests, labeller
with schema and validator, synthetic generator, dedup and split, the three
eval parts with the agreement filter, and the manifest.
Deliverable: a labelled set of 10,000 to 30,000 contexts and an eval set of
about 60 tool-call boxes, 300 synthetic contexts and 300 to 500 agreed real
contexts, all local, with the manifest in git.

**Phase 2. Training and eval. 2 to 3 days.**
`train.py` and `eval.py`, a small sweep on the M5 Max (learning rate, epochs,
negative ratio), error analysis per eval part, targeted data fixes. If
Ettin-32m misses the targets, train Ettin-150m.
Deliverable: a checkpoint that meets the targets, with the eval report in
the manifest.

**Phase 3. Conversion and benchmarks. 1 to 2 days.**
`convert.py` and `bench.py`: enumerated shapes, compute-unit choice, optional
palettisation, the logits check. Deliverable:
`data/output/ParagraphTagger.mlpackage`, its hash, size and latency table.

**Phase 3b. Test CLI. Half a day.**
A Python command-line tool, `app/ml/tagger.py`, run as `uv run tagger`. It
uses the same Hugging Face tokenizer (with its offsets) and the same
tags-to-spans code as `eval.py`, so there is one Python implementation.

    uv run tagger [FILE]
        reads a context (logical lines, `>` on the hovered lines, optional
        `**` bold markers) from FILE or stdin
        --backend torch|coreml   the checkpoint, or the converted
                                 data/output/ParagraphTagger.mlpackage
        --compute cpu|gpu|ane|all   Core ML compute units
        --hover N        mark line N as hovered instead of reading `>`
        --json           the result as JSON; else a readable listing
        --bench N        run N times, print load time and p50/p95 latency

The readable output shows each line with its line class, the question text,
the options with their character ranges, the unit range and `isQuestion`.
The JSON has the same fields as `ParagraphAnswer` plus the exact ranges and
the per-token tags. `--backend coreml` runs the `.mlpackage` through
coremltools' `predict` on this Mac, so the CLI also checks the conversion.
Deliverable: the CLI and a `make cli` target.

**Phase 4. App integration. 3 to 4 days.**
Decide the binary's storage. If phase 0 kept bold markers: the Ghostty
fork change to read the bold attribute per cell, and the markers in the rows
that the app reads, with their offset mapping. The SwiftPM package
`app/Packages/ParagraphTagger`: the tokenizer with offsets, the Core ML call
and tags to spans. Its test runs the eval contexts and compares the result
with `uv run tagger --backend coreml --json`, within 0.5 F1 points, which
checks the Swift tokenizer offsets. The app links the package, with lazy
load,
`ParagraphModel.analyze` calling it, the package, model and tokenizer in
`project.yml`, a visual test of the tagger on one fixture context, the
canned analyzer unchanged. Phase 4b adds exact ranges to `ParagraphAnswer`.
Deliverable: the feature runs on the tagger; FoundationModels still answers
only when the tagger throws; `docs/design-app.md` "Shift paragraphs" updated
by the manager.

**Phase 5. Use, retrain, delete FoundationModels. 1 to 2 weeks of use,
then 1 day.**
Use the feature with `KIDO_APP_DEBUG=1`, add the misses to the eval set,
retrain. When the tagger meets the targets on the grown eval set, delete the
`FoundationModels` call, the `unavailable` state, its captions,
`testAvailability`, and the framework from `project.yml`; a tagger failure
is `failed` as today. Deliverable: one analyzer, a shorter
`ParagraphMode`, the design section and `NOTES.md` without the on-device
model, and the eval report.

## Phase 0 results

Measured on 2026-10-20 on the M5 Max (64 GB). Code: `app/ml/`. The full
report is `app/ml/data/phase0-report.md` (gitignored, counts only).
No transcript text is in git.

### Data

- 419 rendered contexts from 366 sessions: 130 pi, 264 Claude Code,
  25 `AskUserQuestion`. There are 16 `AskUserQuestion` calls with
  26 questions, not 60 calls.
- `deepseek-flash` (non-thinking, JSON mode) labelled the redacted
  contexts; the 25 `AskUserQuestion` contexts take their labels from the
  call, with no API call. 392 labels are valid, 24 are dropped.
- Dedup removed 35 exact and 13 near duplicates. The session-level split:
  train 264 examples (247 sessions), eval 83 (62 sessions; 20 ask,
  41 Claude, 22 pi; 43 negatives). The dev split for hyperparameters
  comes from train sessions only (210 / 54).
- Option spans: real train 34, dev 2, real eval 67 (ask 58, pi 9).
  Synthetic train adds 163 option spans in 208 examples; the synthetic
  eval uses held-out templates.

### Token counts (Ettin tokenizer, real contexts)

Min 36, p50 240, p90 457, p99 837, max 929. 27 contexts (6.4%) exceed
512 tokens; none exceed 1,024. A first render had one context of 2,120
tokens, so 2,048 stays as the rare fallback shape.

### Quality (real eval, 83 contexts)

Ettin-32m: 20 epochs, lr 1e-4 with warmup and linear decay, batch 8,
max length 1,024, bf16. Chosen on the dev split. Mean ± SD over 3 seeds;
Create ML has one run.

| Model | Train data | Bold | Question F1 | Option exact F1 | Unit accuracy | Question FPR |
|---|---|---|---:|---:|---:|---:|
| Create ML `MLWordTagger` | real | yes | 0.648 | 0.000 | 0.699 | 2.3% |
| Create ML `MLWordTagger` | real | no | 0.623 | 0.110 | 0.723 | 2.3% |
| Ettin-32m | real | yes | 0.855 ± 0.022 | 0.008 ± 0.014 | 0.835 ± 0.030 | 1.6% |
| Ettin-32m | real | no | 0.858 ± 0.029 | 0.000 | 0.811 ± 0.018 | 1.6% |
| Ettin-32m | real + synthetic | yes | 0.832 ± 0.044 | 0.069 ± 0.043 | 0.767 ± 0.039 | 2.3% |
| Ettin-32m | real + synthetic | no | 0.844 ± 0.035 | 0.243 ± 0.181 | 0.815 ± 0.069 | 3.1% |

Best single model (real + synthetic, no bold, seed 0): question F1
0.877, option exact F1 0.440 (ask part 0.490), unit accuracy 0.892,
FPR 2.3%. Of 67 gold options: 24 exact, 12 partial, 31 missed,
6 spurious inside a gold unit, 0 spurious in a negative context.

Learning curve (Ettin, real train only, question F1 at 25 / 50 / 100% of
the train sessions): bold 0.661 / 0.681 / 0.855, no bold 0.587 / 0.538 /
0.858. Create ML: 0.41 to 0.65. Question detection gains from more
data. Option detection is zero without option training data and rises
at once with 163 synthetic option spans.

With 83 eval contexts, one error moves the FPR by about 2 points, and the
seed spread of option exact F1 is 0.09 to 0.44. These numbers show a
trend, not the phase 2 targets.

### Training

Ettin-32m on 264 examples × 20 epochs: 62 s. Throughput 23,600 to 24,000
real tokens/s (24,500 to 25,000 padded) after warmup. Peak memory: 0.39 GB
allocated, 7 to 8 GB in the MPS driver with a length-bucketed sampler. At
this rate, 30,000 contexts × 3 epochs (about 23M tokens) takes about
16 minutes. Create ML trains in 5 s; its model is about 0.8 MB.

### Core ML

- `EnumeratedShapes` puts every op on the CPU for `CPU_AND_NE`
  (checked with `MLComputePlan`). The working form is one fixed-shape
  function for each length in one multifunction package. Then 415 ops run
  on the Neural Engine and 5 on the CPU.
- Size: fp16 multifunction package (512, 1,024, 2,048) 76.4 MB. 8-bit
  palettisation gives 32.6 MB for one function; coremltools cannot
  palettise a multifunction package.
- The converted checkpoint is the real-only no-bold model (seed 2); the
  conversion numbers depend on the architecture, not on the weights. The
  PyTorch wrapper equals the Hugging Face model (max difference 0).
  Core ML against PyTorch: argmax agreement 0.9998 at 512 and 1.0 at
  1,024; KL 3e-7 (GPU) and 1.5e-6 (ANE) at 512. No real context reaches
  2,048, so that shape has no logits check.

Latency, p50 / p95 ms, compiled model, fresh process per row (load ms):

| Compute unit | 512 | 1,024 | 2,048 | Load |
|---|---:|---:|---:|---:|
| CPU only | 9.99 / 10.47 | 24.67 / 25.17 | 71.52 / 72.31 | 105 to 161 |
| CPU and GPU | 2.36 / 2.90 | 2.35 / 3.64 | 5.55 / 5.72 | 143 to 167 |
| CPU and ANE | 5.51 / 5.57 | 17.71 / 17.86 | 56.81 / 57.00 | 1,528 to 3,544 |
| All | 2.10 / 2.46 | 2.60 / 2.74 | 5.53 / 5.69 | 296 to 317 |

The 2,048 row uses a synthetic prompt of 1,600 tokens.

### Swift tokenizer offsets

swift-transformers 1.3.5 with Ettin's `tokenizer.json`, 10 hard cases
(box drawing, ZWJ emoji, CJK, combining marks, tabs, CRLF, `**`, code):
all token ids match Hugging Face, and 140 of 140 offsets match. The
method needs one step beyond cumulative byte lengths: the tokenizer
normalises to NFC, and the library does not expose the normaliser, so
the code maps NFC positions back to the original text. Without that
mapping, 4 of 134 offsets in combining text fail. No custom BPE encoder
is needed.

### Ghostty bold attribute

`ghostty_surface_read_text` and `ghostty_surface_read_selection` (read in
`app/App/PaneView.swift`) return text only; `ghostty_text_s` has no
style field. The core has the data (`page.Cell.style_id`,
`Style.flags.bold`, and `selectionStringMap` maps text bytes to cells).
A fork change adds a per-byte style array to `ghostty_text_s`, fills it
in `Surface.dumpTextLocked`, frees it in `ghostty_surface_free_text`, and
reads it in the app's text decoding: about 80 to 120 Zig lines, 10 header
lines and 20 Swift lines.

### Go / no-go

- **Model: go for Ettin-32m.** It beats the Create ML baseline on every
  real metric, question detection is at 0.86 F1 with 264 training
  contexts and still rising, and option detection responds to option
  data. Option quality is not proven; phase 1 must supply option data
  (see below), and phase 2 decides against the targets. Create ML is
  dropped.
- **ANE: no-go as the default.** It works with fixed shapes and keeps the
  logits, but it is 2 to 10 times slower than the GPU and loads in 1.5 to
  3.5 s. Use `.cpuAndGPU`: about 2.4 ms at 1,024 tokens, about 150 ms
  load. The 100 ms debounce can shrink.
- **Bold markers: no-go for now.** They give no question gain (0.855
  against 0.858) and worse options (0.069 against 0.243 exact F1). Phase 4
  does not do the Ghostty fork change. Phase 2 repeats the A/B once on the
  large set; only a clear gain brings the change back.

### Changes for later phases

- Phase 1: real labels yield few options (34 in 264 contexts), and every
  `AskUserQuestion` context is eval data. Label more contexts with a
  question at the end (about 1,200 pi turns), oversample option-bearing
  ones, and keep synthetic option data in training. Make the synthetic
  templates more varied: half of the first generation were near
  duplicates, and held-out templates scored much lower than training
  templates.
- Phase 1: the eval's exact tool-call part is 26 questions, not 60. The
  agreed real part (`deepseek-v4-pro`) carries more of the eval.
- Phase 2: report the mean over 3 seeds; one seed is not enough. Select
  hyperparameters on the dev split, never on eval. The dev split needs
  enough option spans to rank configurations (it had 2).
- Phase 3: convert to one fixed-shape function per length, not
  `EnumeratedShapes`. Check the op placement with `MLComputePlan` in
  `convert.py`. Use 512 and 1,024; keep 2,048 only as a fallback. Choose
  8-bit palettisation per function only if the bundle size matters.
- Phase 4: the Swift tokenizer needs the NFC position mapping.
  `computeUnits = .cpuAndGPU`. No bold markers and no Ghostty change
  unless phase 2 reverses the bold result.
- Hardware: the MPS driver peak is 7 to 8 GB, not under 10 GB of
  allocations; the M5 Max is enough. Phase 2 sweeps over the 32m model
  take minutes, not hours.

## Phase 1 data

Built on 2026-10-20. The full tables are in `app/ml/data/phase1-report.md`
(gitignored, counts only). `app/ml/manifest.json` holds only what the stages
record: counts, hashes, settings, prompt hash, redaction version, seed,
DeepSeek model versions and spend. `make pipeline` runs the stages as file
targets: render, session plan (frozen), label, eval-label, eval set, split,
manifest, report; synthetic runs on its own.

**Rendering and selection.** 4,106 rendered contexts (3,557 distinct) from
1,106 pi and Claude Code sessions; 11,480 examples after hover variants.
Labels do not depend on the hover: the labeller gets the context without the
`>` marker, labels each context family once, and the label is attached to
every hover variant. (With the old per-hover prompt, 323 of 2,949 families
got different labels for different hovers.) The session plan assigns 212
sessions to eval before any labelling: 600 distinct eval families, 300 with a
question mark and 300 without. Eval sessions and context families never
appear in train or dev (union over session and family).

**Splits** (examples; positive = the hovered paragraph is in a question
unit; option spans split into list lines and inline options):

| Split | Part | Examples | Positive | Negative | Option spans (list / inline) | Families | Sessions |
|---|---|---:|---:|---:|---:|---:|---:|
| train | Claude Code | 2,797 | 241 | 2,556 | 141 / 18 | 822 | 274 |
| train | pi | 4,004 | 165 | 3,839 | 154 / 25 | 1,231 | 593 |
| train | synthetic | 4,941 | 2,670 | 2,271 | 4,756 / 966 | 4,941 | 1,526 |
| eval | tool call | 21 | 21 | 0 | 60 / 0 | 21 | 8 |
| eval | real (`deepseek-v4-pro`) | 1,567 | 206 | 1,361 | 0 / 139 | 496 | 150 |
| eval | held-out synthetic | 287 | 154 | 133 | 248 / 50 | 287 | 76 |

Train: 11,742 examples (6,801 real, 4,941 synthetic), 74% negative; 112
variants of 34 rejected families have no label. Dev (from train sessions):
1,764 examples, 365 sessions, 932 option spans, of which 60 are real. Dedup
removed 1,073 near duplicates from train, and 5 exact and 15 near duplicates
from eval. The synthetic generator has 22 train and 12 eval template families.
Real data is option-poor: about 2,050 labelled real train families hold 338
option spans in their hover variants.

**Labellers.** One option convention, applied in `validate.py` to every
label: an option on a list-marker line has the line class `option`; an
option inside a question sentence is inline and its line stays `question`.

| Labeller | Families | Accepted | Rejected or dropped | Cost |
|---|---:|---:|---:|---:|
| `deepseek-flash` (V4.1-Flash-1017), non-thinking, 1 sample | 2,101 | 2,067 | 34 (1.6%) | $2.51 |
| `deepseek-v4-pro` (V4-Pro-0813), thinking, 5 samples | 600 | 498 | 75 disagree, 27 invalid | $18.37 |
| `deepseek-v4-pro` diagnostic on train families, 1 sample | 300 | 265 | 35 | $1.66 |

Total spend for phase 1: $22.53 (cache hits at the hit price), off-peak.
The first flash run paid for every context twice (about $1.1 lost) because
resume keyed on record ids; the response cache now keys on the request body. Flash
rejections by class: missing option text 59, option markup 21, no question
11, duplicate option 6, other 2. DeepSeek ignores `temperature` in thinking
mode, so the 5 samples differ only by the model's own sampling; the filter
still rejected 17% of the contexts.

**Labeller disagreement** (300 train families with a question, flash
against one v4-pro sample, after the option convention): line classes agree
in 86%, the question unit in 93%, the option set in 74%. Where the option
sets differ, v4-pro has more inline options in 47 families, more list
options in 15, flash has more in 2. Flash under-labels inline options.

**Sanity check, not a phase 2 result.** Ettin-32m, one epoch, one seed, no
bold: question F1 0.939, option exact F1 0.743, unit accuracy 0.990,
question FPR 0.27%. On the real eval part alone option exact F1 is 0.029:
its 139 option spans are all inline, and the real train labels hold only 43
inline spans.

**Changes for phase 2.**

- Inline options are the gap. The real eval's options are inline, and flash
  under-labels them. Before training, relabel the train families that have a
  question with `deepseek-v4-pro` (one sample, thinking; about $2 for the
  370 families with a question, about $11 for all 2,067), or add inline options to the flash prompt and measure
  it again with the diagnostic. Add more inline forms to the synthetic train
  families.
- The real eval part and the training labels then come from the same model.
  The plan's limit "agreement with a stronger model, not with the user"
  applies more strongly; phase 5's misses stay the only correction.
- Real option spans in dev are 60; rank configurations on the real dev part
  separately from the synthetic part.

## Later

Rules for known formats (the `AskUserQuestion` box, pi's dialog) and the
agent's own question record are possible layers in front of the tagger.
They are out of scope for now.
