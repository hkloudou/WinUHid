//go:build windows

package vhid

import (
	"errors"
	"sync"
)

// keyboardReportDescriptor describes a standard keyboard: one byte of modifier keys, one
// reserved byte, then up to six keys held at the same time (the classic 8-byte report).
var keyboardReportDescriptor = []byte{
	0x05, 0x01, // Usage Page (Generic Desktop)
	0x09, 0x06, // Usage (Keyboard)
	0xA1, 0x01, // Collection (Application)
	0x05, 0x07, //   Usage Page (Keyboard/Keypad)
	0x19, 0xE0, //   Usage Minimum (Left Control)
	0x29, 0xE7, //   Usage Maximum (Right GUI)
	0x15, 0x00, //   Logical Minimum (0)
	0x25, 0x01, //   Logical Maximum (1)
	0x75, 0x01, //   Report Size (1)
	0x95, 0x08, //   Report Count (8)
	0x81, 0x02, //   Input (Data, Variable, Absolute): the eight modifier keys
	0x95, 0x01, //   Report Count (1)
	0x75, 0x08, //   Report Size (8)
	0x81, 0x01, //   Input (Constant): reserved byte
	0x95, 0x06, //   Report Count (6)
	0x75, 0x08, //   Report Size (8)
	0x15, 0x00, //   Logical Minimum (0)
	0x25, 0x65, //   Logical Maximum (101)
	0x05, 0x07, //   Usage Page (Keyboard/Keypad)
	0x19, 0x00, //   Usage Minimum (0)
	0x29, 0x65, //   Usage Maximum (101)
	0x81, 0x00, //   Input (Data, Array): up to six keys
	0xC0, // End Collection
}

// Key is a key's number on the HID "Keyboard/Keypad" usage page. It names a physical key
// position; which character that key produces depends on the keyboard layout chosen in Windows.
type Key byte

// A few common keys. Letters run from KeyA (0x04) to KeyZ (0x1D), digits from Key1 (0x1E) to
// Key9 (0x26) followed by Key0 (0x27). Keys up to 0x65 can be used.
const (
	KeyA         Key = 0x04
	KeyZ         Key = 0x1D
	Key1         Key = 0x1E
	Key0         Key = 0x27
	KeyEnter     Key = 0x28
	KeyEscape    Key = 0x29
	KeyBackspace Key = 0x2A
	KeyTab       Key = 0x2B
	KeySpace     Key = 0x2C

	KeyLeftControl  Key = 0xE0
	KeyLeftShift    Key = 0xE1
	KeyLeftAlt      Key = 0xE2
	KeyLeftGUI      Key = 0xE3 // the Windows key
	KeyRightControl Key = 0xE4
	KeyRightShift   Key = 0xE5
	KeyRightAlt     Key = 0xE6
	KeyRightGUI     Key = 0xE7
)

// Keyboard is a virtual keyboard. It is safe for concurrent use.
type Keyboard struct {
	mu        sync.Mutex
	device    *Device
	modifiers byte
	keys      [6]byte
}

// NewKeyboard creates a virtual keyboard with the given identifiers. Use identifiers that are yours.
func NewKeyboard(vendorID, productID uint16) (*Keyboard, error) {
	device, err := CreateDevice(Config{
		VendorID:         vendorID,
		ProductID:        productID,
		ReportDescriptor: keyboardReportDescriptor,
	})
	if err != nil {
		return nil, err
	}
	return &Keyboard{device: device}, nil
}

// send reports which keys are held right now. The caller holds k.mu.
func (k *Keyboard) send() error {
	report := [8]byte{k.modifiers, 0, k.keys[0], k.keys[1], k.keys[2], k.keys[3], k.keys[4], k.keys[5]}
	return k.device.SubmitInputReport(report[:])
}

func isModifier(key Key) bool { return key >= KeyLeftControl && key <= KeyRightGUI }

// KeyDown presses a key and keeps it held until KeyUp or ReleaseAll.
func (k *Keyboard) KeyDown(key Key) error {
	k.mu.Lock()
	defer k.mu.Unlock()
	if isModifier(key) {
		k.modifiers |= 1 << (key - KeyLeftControl)
		return k.send()
	}
	if key == 0 || key > 0x65 {
		return errors.New("vhid: key outside the range this keyboard reports")
	}
	free := -1
	for i, held := range k.keys {
		if held == byte(key) {
			return nil // already held
		}
		if held == 0 && free < 0 {
			free = i
		}
	}
	if free < 0 {
		return errors.New("vhid: six keys are already held")
	}
	k.keys[free] = byte(key)
	return k.send()
}

// KeyUp releases a key.
func (k *Keyboard) KeyUp(key Key) error {
	k.mu.Lock()
	defer k.mu.Unlock()
	if isModifier(key) {
		k.modifiers &^= 1 << (key - KeyLeftControl)
		return k.send()
	}
	for i, held := range k.keys {
		if held == byte(key) {
			k.keys[i] = 0
		}
	}
	return k.send()
}

// ReleaseAll releases every key.
func (k *Keyboard) ReleaseAll() error {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.modifiers = 0
	k.keys = [6]byte{}
	return k.send()
}

// KeyForRune returns the key, and whether Shift is needed, that produces the character on a
// US keyboard layout. ok is false for characters outside printable ASCII, Enter and Tab.
func KeyForRune(r rune) (key Key, shift bool, ok bool) {
	switch {
	case r >= 'a' && r <= 'z':
		return KeyA + Key(r-'a'), false, true
	case r >= 'A' && r <= 'Z':
		return KeyA + Key(r-'A'), true, true
	case r >= '1' && r <= '9':
		return Key1 + Key(r-'1'), false, true
	case r == '0':
		return Key0, false, true
	case r == '\n':
		return KeyEnter, false, true
	case r == '\t':
		return KeyTab, false, true
	case r == ' ':
		return KeySpace, false, true
	}
	// The remaining keys of a US layout: unshifted character, shifted character, key.
	const unshifted = "-=[]\\;'`,./"
	const shifted = "_+{}|:\"~<>?"
	codes := [...]Key{0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38}
	for i := range codes {
		if r == rune(unshifted[i]) {
			return codes[i], false, true
		}
		if r == rune(shifted[i]) {
			return codes[i], true, true
		}
	}
	const shiftedDigits = "!@#$%^&*()"
	for i, c := range shiftedDigits {
		if r == c {
			return Key1 + Key(i), true, true
		}
	}
	return 0, false, false
}

// Close releases every key and removes the keyboard from Windows.
// The Keyboard must not be used afterwards.
func (k *Keyboard) Close() error {
	k.mu.Lock()
	defer k.mu.Unlock()
	if k.modifiers != 0 || k.keys != [6]byte{} {
		k.modifiers = 0
		k.keys = [6]byte{}
		_ = k.send()
	}
	return k.device.Close()
}
