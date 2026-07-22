package cgobridge

import "testing"

func TestDatabaseCloseConsumesHandle(t *testing.T) {
	tests := []struct {
		name     string
		code     ErrorCode
		consumed bool
	}{
		{name: "success", code: ErrorOK, consumed: true},
		{name: "sync failure", code: ErrorIO, consumed: true},
		{name: "active child", code: ErrorInvalidArg, consumed: false},
		{name: "unknown failure", code: ErrorGeneric, consumed: false},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := databaseCloseConsumesHandle(test.code); got != test.consumed {
				t.Fatalf("databaseCloseConsumesHandle(%d) = %t, want %t", test.code, got, test.consumed)
			}
		})
	}
}
