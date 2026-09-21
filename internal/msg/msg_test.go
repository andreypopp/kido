package msg

import "testing"

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
