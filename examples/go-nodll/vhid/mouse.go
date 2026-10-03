//go:build windows

package vhid

import (
	"errors"
	"sync"
)

var errInvalidButton = errors.New("vhid: unknown mouse button")

// mouseReportDescriptor describes a five-button relative mouse with a vertical wheel and
// horizontal scrolling. Its report is 7 bytes: buttons, X (16 bit), Y (16 bit), wheel, pan.
var mouseReportDescriptor = []byte{
	0x05, 0x01, // Usage Page (Generic Desktop)
	0x09, 0x02, // Usage (Mouse)
	0xA1, 0x01, // Collection (Application)
	0x09, 0x01, //   Usage (Pointer)
	0xA1, 0x00, //   Collection (Physical)
	0x05, 0x09, //     Usage Page (Button)
	0x19, 0x01, //     Usage Minimum (Button 1)
	0x29, 0x05, //     Usage Maximum (Button 5)
	0x15, 0x00, //     Logical Minimum (0)
	0x25, 0x01, //     Logical Maximum (1)
	0x95, 0x05, //     Report Count (5)
	0x75, 0x01, //     Report Size (1)
	0x81, 0x02, //     Input (Data, Variable, Absolute): five button bits
	0x95, 0x01, //     Report Count (1)
	0x75, 0x03, //     Report Size (3)
	0x81, 0x01, //     Input (Constant): three padding bits
	0x05, 0x01, //     Usage Page (Generic Desktop)
	0x09, 0x30, //     Usage (X)
	0x09, 0x31, //     Usage (Y)
	0x16, 0x01, 0x80, // Logical Minimum (-32767)
	0x26, 0xFF, 0x7F, // Logical Maximum (32767)
	0x75, 0x10, //     Report Size (16)
	0x95, 0x02, //     Report Count (2)
	0x81, 0x06, //     Input (Data, Variable, Relative): X and Y movement
	0x09, 0x38, //     Usage (Wheel)
	0x15, 0x81, //     Logical Minimum (-127)
	0x25, 0x7F, //     Logical Maximum (127)
	0x75, 0x08, //     Report Size (8)
	0x95, 0x01, //     Report Count (1)
	0x81, 0x06, //     Input (Data, Variable, Relative): vertical wheel
	0x05, 0x0C, //     Usage Page (Consumer)
	0x0A, 0x38, 0x02, // Usage (AC Pan)
	0x15, 0x81, //     Logical Minimum (-127)
	0x25, 0x7F, //     Logical Maximum (127)
	0x75, 0x08, //     Report Size (8)
	0x95, 0x01, //     Report Count (1)
	0x81, 0x06, //     Input (Data, Variable, Relative): horizontal scroll
	0xC0, //   End Collection
	0xC0, // End Collection
}

// MouseButton names a button for Mouse.Button.
type MouseButton uint8

const (
	ButtonLeft   MouseButton = 1
	ButtonRight  MouseButton = 2
	ButtonMiddle MouseButton = 3
	ButtonX1     MouseButton = 4 // "back"
	ButtonX2     MouseButton = 5 // "forward"
)

// Mouse is a virtual relative mouse: five buttons, wheel, horizontal scroll.
// It is safe for concurrent use.
type Mouse struct {
	mu      sync.Mutex
	device  *Device
	buttons byte
}

// NewMouse creates a virtual mouse with the given identifiers. Use identifiers that are yours.
func NewMouse(vendorID, productID uint16) (*Mouse, error) {
	device, err := CreateDevice(Config{
		VendorID:         vendorID,
		ProductID:        productID,
		ReportDescriptor: mouseReportDescriptor,
	})
	if err != nil {
		return nil, err
	}
	return &Mouse{device: device}, nil
}

// send reports the held buttons together with one step of movement or scrolling.
// The caller holds m.mu.
func (m *Mouse) send(dx, dy int16, wheel, pan int8) error {
	report := [7]byte{
		m.buttons,
		byte(dx), byte(uint16(dx) >> 8),
		byte(dy), byte(uint16(dy) >> 8),
		byte(wheel),
		byte(pan),
	}
	return m.device.SubmitInputReport(report[:])
}

// Move moves the pointer by a relative amount. Like a physical mouse, the distance on screen
// also depends on the user's pointer speed and acceleration settings.
func (m *Mouse) Move(dx, dy int16) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.send(dx, dy, 0, 0)
}

// Button presses (down = true) or releases a button. Other buttons keep their state.
func (m *Mouse) Button(button MouseButton, down bool) error {
	if button < ButtonLeft || button > ButtonX2 {
		return errInvalidButton
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	mask := byte(1) << (button - 1)
	if down {
		m.buttons |= mask
	} else {
		m.buttons &^= mask
	}
	return m.send(0, 0, 0, 0)
}

// Scroll turns the wheel by whole notches: positive is up (away from the user), negative is down.
func (m *Mouse) Scroll(notches int8) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.send(0, 0, notches, 0)
}

// ScrollHorizontal scrolls sideways by whole notches: positive is right, negative is left.
func (m *Mouse) ScrollHorizontal(notches int8) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.send(0, 0, 0, notches)
}

// Close releases any held buttons and removes the mouse from Windows.
// The Mouse must not be used afterwards.
func (m *Mouse) Close() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.buttons != 0 {
		m.buttons = 0
		_ = m.send(0, 0, 0, 0)
	}
	return m.device.Close()
}
