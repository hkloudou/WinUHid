//go:build windows

package winuhid

import "testing"

func TestKeyForRune(t *testing.T) {
	cases := []struct {
		r     rune
		key   Key
		shift bool
	}{
		{'a', 0x04, false}, {'Z', 0x1D, true}, {'1', 0x1E, false}, {'0', 0x27, false},
		{'!', 0x1E, true}, {')', 0x27, true}, {' ', 0x2C, false}, {'\n', 0x28, false},
		{'-', 0x2D, false}, {'_', 0x2D, true}, {'\\', 0x31, false}, {'|', 0x31, true},
		{';', 0x33, false}, {'"', 0x34, true}, {'`', 0x35, false}, {'/', 0x38, false}, {'?', 0x38, true},
	}
	for _, c := range cases {
		key, shift, ok := KeyForRune(c.r)
		if !ok || key != c.key || shift != c.shift {
			t.Errorf("KeyForRune(%q) = %#x, %v, %v; want %#x, %v", c.r, key, shift, ok, c.key, c.shift)
		}
	}
	if _, _, ok := KeyForRune('中'); ok {
		t.Error("KeyForRune accepted a character that is not on a US keyboard")
	}
}
