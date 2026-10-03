//go:build windows

package vhid

import (
	"errors"
	"sync"
)

// absoluteMouseReportDescriptor describes a pointing device that reports where the pointer
// is, not how far it moved: five buttons, absolute X and Y (0..32767), wheel and horizontal
// scroll. Its report is 7 bytes: buttons, X (16 bit), Y (16 bit), wheel, pan.
var absoluteMouseReportDescriptor = []byte{
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
	0x15, 0x00, //     Logical Minimum (0)
	0x26, 0xFF, 0x7F, // Logical Maximum (32767)
	0x35, 0x00, //     Physical Minimum (0)
	0x46, 0xFF, 0x7F, // Physical Maximum (32767)
	0x75, 0x10, //     Report Size (16)
	0x95, 0x02, //     Report Count (2)
	0x81, 0x02, //     Input (Data, Variable, Absolute): X and Y position
	0x09, 0x38, //     Usage (Wheel)
	0x15, 0x81, //     Logical Minimum (-127)
	0x25, 0x7F, //     Logical Maximum (127)
	0x35, 0x00, //     Physical Minimum (0): none
	0x45, 0x00, //     Physical Maximum (0): none
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

// AbsoluteMax is the largest coordinate of an AbsoluteMouse: (0, 0) is the top-left corner
// of the screen and (AbsoluteMax, AbsoluteMax) its bottom-right corner.
const AbsoluteMax = 32767

// AbsoluteMouse is a virtual pointing device that places the pointer at a position on the
// screen, independent of the user's pointer speed and acceleration settings. Use it to
// operate a desktop. Programs that only follow relative movement (many games) need Mouse.
//
// Every report of such a device carries a position, so buttons and the wheel act at the
// position last given to MoveTo; call MoveTo first. It is safe for concurrent use.
type AbsoluteMouse struct {
	mu         sync.Mutex
	device     *Device
	buttons    byte
	x, y       uint16
	positioned bool
}

// NewAbsoluteMouse creates the device with the given identifiers. Use identifiers that are yours.
func NewAbsoluteMouse(vendorID, productID uint16) (*AbsoluteMouse, error) {
	device, err := CreateDevice(Config{
		VendorID:         vendorID,
		ProductID:        productID,
		ReportDescriptor: absoluteMouseReportDescriptor,
	})
	if err != nil {
		return nil, err
	}
	return &AbsoluteMouse{device: device}, nil
}

var errNotPositioned = errors.New("vhid: call MoveTo before using buttons or the wheel of an absolute mouse")

// send reports the held buttons and the position, with an optional step of scrolling.
// The caller holds m.mu.
func (m *AbsoluteMouse) send(wheel, pan int8) error {
	report := [7]byte{
		m.buttons,
		byte(m.x), byte(m.x >> 8),
		byte(m.y), byte(m.y >> 8),
		byte(wheel),
		byte(pan),
	}
	return m.device.SubmitInputReport(report[:])
}

// MoveTo places the pointer. x and y run from 0 to AbsoluteMax across the screen; larger
// values are clamped.
func (m *AbsoluteMouse) MoveTo(x, y uint16) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.x, m.y = min(x, AbsoluteMax), min(y, AbsoluteMax)
	m.positioned = true
	return m.send(0, 0)
}

// MoveToPixel places the pointer on the pixel (x, y) of a screen that is width by height
// pixels. Values outside the screen are clamped to its edge.
func (m *AbsoluteMouse) MoveToPixel(x, y, width, height int) error {
	return m.MoveTo(AbsoluteFromPixel(x, width), AbsoluteFromPixel(y, height))
}

// AbsoluteFromPixel converts a pixel position along one axis of a screen that is size pixels
// long into the coordinate MoveTo expects, aiming at the middle of that pixel.
func AbsoluteFromPixel(pixel, size int) uint16 {
	if size <= 0 {
		return 0
	}
	if pixel < 0 {
		pixel = 0
	}
	if pixel >= size {
		pixel = size - 1
	}
	return uint16((2*pixel + 1) * (AbsoluteMax + 1) / (2 * size))
}

// Button presses (down = true) or releases a button at the current position.
// Other buttons keep their state.
func (m *AbsoluteMouse) Button(button MouseButton, down bool) error {
	if button < ButtonLeft || button > ButtonX2 {
		return errInvalidButton
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.positioned {
		return errNotPositioned
	}
	mask := byte(1) << (button - 1)
	if down {
		m.buttons |= mask
	} else {
		m.buttons &^= mask
	}
	return m.send(0, 0)
}

// Scroll turns the wheel by whole notches: positive is up (away from the user), negative is down.
func (m *AbsoluteMouse) Scroll(notches int8) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.positioned {
		return errNotPositioned
	}
	return m.send(notches, 0)
}

// ScrollHorizontal scrolls sideways by whole notches: positive is right, negative is left.
func (m *AbsoluteMouse) ScrollHorizontal(notches int8) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.positioned {
		return errNotPositioned
	}
	return m.send(0, notches)
}

// Close releases any held buttons and removes the device from Windows.
// The AbsoluteMouse must not be used afterwards.
func (m *AbsoluteMouse) Close() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.buttons != 0 {
		m.buttons = 0
		_ = m.send(0, 0)
	}
	return m.device.Close()
}
