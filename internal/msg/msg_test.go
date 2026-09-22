package msg

import (
	"encoding/json"
	"os"
	"testing"
)

// discriminatorCase is one row of testdata/discriminator.json: a raw wire
// payload and the v0/v1 verdict Parse must reach for it.
type discriminatorCase struct {
	Name string `json:"name"`
	Raw  string `json:"raw"`
	OK   bool   `json:"ok"`
}

// TestParseAgreesWithSharedDiscriminatorTable drives Parse over
// testdata/discriminator.json, the 11-payload matrix proven to agree
// between Parse and pi/kido-status.ts's parseEnvelope (a TypeScript test
// drives the same file - see its test for "discriminator.json"). msg.Parse
// and parseEnvelope are two implementations of one rule, and the whole
// v0/v1 contract rests on them never drifting apart: a payload one side
// calls an envelope and the other calls raw text is exactly how a user's
// prompt gets swallowed as a control message, or a control message
// reaches the user as literal text. Editing this fixture without updating
// the TypeScript side breaks that guarantee silently; keeping both sides
// reading the same file is what closes that gap.
func TestParseAgreesWithSharedDiscriminatorTable(t *testing.T) {
	raw, err := os.ReadFile("testdata/discriminator.json")
	if err != nil {
		t.Fatalf("reading testdata/discriminator.json: %v", err)
	}
	var cases []discriminatorCase
	if err := json.Unmarshal(raw, &cases); err != nil {
		t.Fatalf("parsing testdata/discriminator.json: %v", err)
	}
	if len(cases) != 11 {
		t.Fatalf("got %d cases, want the full 11-payload matrix", len(cases))
	}
	for _, c := range cases {
		_, ok := Parse([]byte(c.Raw))
		if ok != c.OK {
			t.Errorf("%s: Parse(%q) ok = %v, want %v", c.Name, c.Raw, ok, c.OK)
		}
	}
}

// TestParseEnvelope checks the v1/v0 split: an envelope needs both "v" and
// "kind", and anything else - including a JSON object that just happens to
// be missing one of them - is v0 raw text.
func TestParseEnvelope(t *testing.T) {
	cases := []struct {
		name string
		raw  string
		want bool
	}{
		{"full envelope", `{"v":1,"kind":"message","id":"x","from":{"session":"s1"},"text":"hi"}`, true},
		{"plain text", "hello there", false},
		{"json array", `["v","kind"]`, false},
		{"json scalar", `42`, false},
		{"object missing kind", `{"v":1,"text":"hi"}`, false},
		{"object missing v", `{"kind":"message","text":"hi"}`, false},
		{"object with neither", `{"text":"hi","title":"a plan"}`, false},
		{"empty", "", false},
	}
	for _, c := range cases {
		_, ok := Parse([]byte(c.raw))
		if ok != c.want {
			t.Errorf("%s: Parse(%q) ok = %v, want %v", c.name, c.raw, ok, c.want)
		}
	}
}

// TestParseEnvelopeFields checks that a real envelope round-trips its
// fields, replyTo included.
func TestParseEnvelopeFields(t *testing.T) {
	raw := `{"v":1,"kind":"reply","id":"abc","replyTo":"xyz","from":{"session":"s1","name":"worker-2","pane":"%18"},"text":"42"}`
	env, ok := Parse([]byte(raw))
	if !ok {
		t.Fatalf("Parse(%q): not an envelope", raw)
	}
	want := Envelope{
		V: 1, Kind: KindReply, ID: "abc", ReplyTo: "xyz",
		From: From{Session: "s1", Name: "worker-2", Pane: "%18"},
		Text: "42",
	}
	if env != want {
		t.Errorf("Parse = %+v, want %+v", env, want)
	}
}

// TestNewIDUnique checks that consecutive ids differ, which is all NewID
// promises.
func TestNewIDUnique(t *testing.T) {
	a, b := NewID(), NewID()
	if a == "" || b == "" {
		t.Fatal("NewID returned an empty id")
	}
	if a == b {
		t.Errorf("NewID returned the same id twice: %q", a)
	}
}
