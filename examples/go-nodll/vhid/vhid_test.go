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
	for name, descriptor := range map[string][]byte{"keyboard": keyboardReportDescriptor, "mouse": mouseReportDescriptor, "absolute mouse": absoluteMouseReportDescriptor} {
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

func TestAbsoluteFromPixel(t *testing.T) {
	// Windows turns the device's 0..32767 into 0..65535 and then into a pixel; aiming at the
	// middle of a pixel must come back as that pixel for every pixel of common screen sizes.
	for _, size := range []int{640, 1024, 1366, 1920, 2560, 3840, 7680} {
		previous := -1
		for pixel := 0; pixel < size; pixel++ {
			value := int(AbsoluteFromPixel(pixel, size))
			if value < 0 || value > AbsoluteMax {
				t.Fatalf("size %d pixel %d: value %d out of range", size, pixel, value)
			}
			if value <= previous {
				t.Fatalf("size %d pixel %d: value %d does not increase", size, pixel, value)
			}
			previous = value
			normalised := value * 65535 / AbsoluteMax
			if got := normalised * size / 65536; got != pixel {
				t.Fatalf("size %d pixel %d: maps back to pixel %d", size, pixel, got)
			}
		}
	}
	if AbsoluteFromPixel(-5, 1920) != AbsoluteFromPixel(0, 1920) || AbsoluteFromPixel(5000, 1920) != AbsoluteFromPixel(1919, 1920) {
		t.Error("positions outside the screen are not clamped to its edge")
	}
}
