//go:build windows

package vhid

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

func TestControlCodes(t *testing.T) {
	// Values of the CTL_CODE macro for the definitions in "WinUHid Driver/Public.h".
	cases := map[string][2]uint32{
		"set device info":       {ioctlSetDeviceInfo, 0x22A000},
		"set report descriptor": {ioctlSetReportDescriptor, 0x22A004},
		"create device":         {ioctlCreateDevice, 0x22A010},
		"start device":          {ioctlStartDevice, 0x22A014},
		"get interface version": {ioctlGetInterfaceVersion, 0x222024},
	}
	for name, c := range cases {
		if c[0] != c[1] {
			t.Errorf("%s: control code %#x, want %#x", name, c[0], c[1])
		}
	}
}

func TestDescriptorsAreWellFormed(t *testing.T) {
	for name, descriptor := range map[string][]byte{"keyboard": keyboardReportDescriptor, "mouse": mouseReportDescriptor} {
		depth := 0
		for i := 0; i < len(descriptor); {
			prefix := descriptor[i]
			size := int(prefix & 0x03)
			if size == 3 {
				size = 4
			}
			switch prefix & 0xFC {
			case 0xA0: // Collection
				depth++
			case 0xC0: // End Collection
				depth--
			}
			i += 1 + size
			if i > len(descriptor) {
				t.Fatalf("%s descriptor: an item runs past the end", name)
			}
		}
		if depth != 0 {
			t.Errorf("%s descriptor: collections are not balanced (depth %d)", name, depth)
		}
	}
}
