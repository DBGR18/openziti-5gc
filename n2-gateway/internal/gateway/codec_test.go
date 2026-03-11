package gateway

import (
	"bytes"
	"testing"
)

func TestFrameRoundTrip(t *testing.T) {
	original := Frame{
		Type:      FrameTypeData,
		SessionID: 42,
		Stream:    7,
		Flags:     3,
		PPID:      60,
		Context:   11,
		TTL:       12,
		Payload:   []byte("ngap"),
	}

	encoded, err := original.MarshalBinary()
	if err != nil {
		t.Fatalf("MarshalBinary() error = %v", err)
	}

	decoded, err := UnmarshalFrame(encoded)
	if err != nil {
		t.Fatalf("UnmarshalFrame() error = %v", err)
	}

	if decoded.Type != original.Type ||
		decoded.SessionID != original.SessionID ||
		decoded.Stream != original.Stream ||
		decoded.Flags != original.Flags ||
		decoded.PPID != original.PPID ||
		decoded.Context != original.Context ||
		decoded.TTL != original.TTL ||
		!bytes.Equal(decoded.Payload, original.Payload) {
		t.Fatalf("decoded frame mismatch: got %+v want %+v", decoded, original)
	}
}

func TestUnmarshalFrameRejectsShortData(t *testing.T) {
	if _, err := UnmarshalFrame([]byte("short")); err == nil {
		t.Fatal("expected error for short frame")
	}
}
