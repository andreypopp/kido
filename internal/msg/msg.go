// Package msg is kido's inbox wire protocol: a v0 payload is raw prompt
// text, sent and read exactly as it always has been; a v1 payload is a
// JSON envelope carrying a sender, a kind, and (for kind ask/reply) a way
// to correlate a question with its answer. The receiving side lives in
// pi/kido-status.ts, which mirrors Parse's rule.
package msg

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
)

// V1 is the only envelope version kido speaks so far.
const V1 = 1

// Kind is what an envelope carries.
type Kind string

const (
	KindMessage   Kind = "message"   // fire-and-forget text
	KindAsk       Kind = "ask"       // a question expecting a reply envelope
	KindReply     Kind = "reply"     // the answer to an earlier ask, by ReplyTo
	KindNotice    Kind = "notice"    // informational, no reply expected
	KindSteer     Kind = "steer"     // a course correction, delivered into the receiver's running turn
	KindInterrupt Kind = "interrupt" // abort the receiver's current turn; it stays alive
	KindStop      Kind = "stop"      // end the receiver's session
)

// From identifies who sent an envelope. It is advisory, not
// authenticated: a sender fills it from its own state.Session record.
type From struct {
	Session string `json:"session"`
	Name    string `json:"name,omitempty"`
	Pane    string `json:"pane,omitempty"`
}

// Envelope is kido's v1 inbox payload: one JSON object, sent over the
// inbox socket exactly like v0 raw text - written whole, then CloseWrite,
// with no other framing.
type Envelope struct {
	V       int    `json:"v"`
	Kind    Kind   `json:"kind"`
	ID      string `json:"id"`
	From    From   `json:"from"`
	ReplyTo string `json:"replyTo,omitempty"`
	Text    string `json:"text"`
}

// Parse reports whether raw is a v1 envelope: a JSON object carrying both
// "v" and "kind". Anything else, including a JSON object missing either
// key, is v0 raw prompt text; a user prompt that is itself a JSON object
// must not be swallowed as a control message.
func Parse(raw []byte) (Envelope, bool) {
	var probe map[string]json.RawMessage
	if err := json.Unmarshal(raw, &probe); err != nil {
		return Envelope{}, false
	}
	if _, ok := probe["v"]; !ok {
		return Envelope{}, false
	}
	if _, ok := probe["kind"]; !ok {
		return Envelope{}, false
	}
	var env Envelope
	if err := json.Unmarshal(raw, &env); err != nil {
		return Envelope{}, false
	}
	return env, true
}

// NewID returns a fresh envelope id, unique enough to correlate a reply
// with its ask across a tmux session's lifetime. crypto/rand.Read does not
// fail on any platform Go supports, so its error is not checked.
func NewID() string {
	b := make([]byte, 16)
	rand.Read(b) //nolint:errcheck // crypto/rand.Read never fails
	return hex.EncodeToString(b)
}
