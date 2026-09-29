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
// testdata/discriminator.json, the same 11-payload matrix a TypeScript
// test drives against pi/kido-status.ts's parseEnvelope, so the v0/v1
// contract cannot drift between the two implementations.
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

func TestNewIDUnique(t *testing.T) {
	a, b := NewID(), NewID()
	if a == "" || b == "" {
		t.Fatal("NewID returned an empty id")
	}
	if a == b {
		t.Errorf("NewID returned the same id twice: %q", a)
	}
}
