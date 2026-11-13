# Reply annotations

A pi extension can annotate a reply of the agent: it marks spans of
the reply's text with a type and that type's data, for example a
question with its options. koa's page renders the annotation types it
knows and ignores the rest. This document is the contract between a
producer (any pi extension) and the consumer (koa). A producer reads
this document and writes the entry; it imports nothing from Kido.
The first producer is `pi-infer-questions`.

## The entry

A producer appends one custom session entry with `pi.appendEntry`:

    customType: "reply-annotations"
    data: {
      reply: { at: number; block: number; length: number };
      annotations: Annotation[];
    }

A custom entry never enters the model's context, and pi's TUI renders
it only when an extension registers a renderer for it, so an
annotation costs the model nothing. pi's session emits the entry as
an `entry_appended` event, and its session manager's entries return
it on a replay.

The contract has no version field. A consumer ignores a field that it
does not know, and drops an annotation that lacks a field that it
needs. Neither side writes a compatibility path: when the contract
changes, the producer and the consumer change together.

## The reply key

`reply` names the text block that the annotations describe:

- `at` is the assistant message's `timestamp` in milliseconds, the
  field that pi persists in the message and returns from
  `get_messages`. The producer has it in its `message_end` event. pi
  gives an extension no entry id at `message_end`, and `get_messages`
  carries no entry ids, so the message's own field is the key.
- `block` is the index of the text block in the message's `content`,
  among all content blocks (text, thinking and tool calls).
- `length` is the length of the text block in Unicode code points, as
  pi stores it, untrimmed. A consumer whose block has another length
  drops the whole entry: the annotation is stale or belongs to another
  text.

One entry describes one text block. A second entry for the same
`reply` replaces the first in the consumer. A reply with several text
blocks gets one entry for each block that has annotations.

## Ranges

A range is `[start, end)` in Unicode code-point offsets into the text
block's Markdown source, as pi stores it, untrimmed. Code points, not
UTF-16 units, because the producer is not necessarily JavaScript. A
consumer converts once at its edge.

A consumer drops a span that is reversed, that is out of the block's
range, or, for an option, that is not inside its question's range. It
also drops a question that overlaps a question that starts earlier in
the text, and an option that overlaps an earlier option of its
question, so the spans that it renders are disjoint. It keeps the other
spans of the same entry.

The producer guarantees that a range boundary falls on a character of
the text, never inside a Markdown delimiter run (`**`, `` ` ``) or a
URL, and that a range that overlaps a code span covers the whole code
span. The consumer does not check this: it parses no Markdown to
validate a span, and its checks are the rules above. It relies
on the guarantee when it inserts its markers at the boundaries before
it renders the Markdown, so that the markers stay out of the syntax.

## Annotation types

    Annotation =
      { type: "question"; range: [number, number];
        kind: "choice" | "yes_no" | "open"; options: [number, number][] }

A consumer drops an annotation whose `type` it does not know, and a
`question` whose `kind` it does not know. It creates nothing for an
entry whose annotations are all dropped.

**`question`.** The text of the question is `range`, usually one
sentence or one list item, including the item's marker. `kind` says
what answers it: `choice` has `options`, each a span inside `range`
with the text of one alternative; `yes_no` is a question or a proposal
that the user accepts or refuses; `open` asks for a fact or a text.
`options` are ignored for a kind other than `choice`.

koa renders a question with controls after it and lets a click put the
quoted question and an answer into the composer. The labels follow
pi-infer-questions' TUI: `open` gets `Answer`; `yes_no` gets `Yes`,
`No` and `Other`; `choice` gets its options in place and `Other`, and
`Yes` and `Other` when it has one option. The composer text is one
block per question: each line of the question's text as a `> ` quote
line, a blank line and the answer; a second click on the same question
replaces its answer. The question text for the quote is the Markdown
of `range` with links and images reduced to their text, `` ` ``, `*`,
`__` and `~~` removed, spaces collapsed, lines trimmed and empty lines
dropped.
