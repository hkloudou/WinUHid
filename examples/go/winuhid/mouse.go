//go:build windows

package winuhid

import (
	"errors"
	"unsafe"
)

// MouseButton names a button for Mouse.Button.
type MouseButton uint8

const (
	ButtonLeft   MouseButton = 1
	ButtonRight  MouseButton = 2
	ButtonMiddle MouseButton = 3
	ButtonX1     MouseButton = 4 // "back"
	ButtonX2     MouseButton = 5 // "forward"
)

// WheelNotch is the scroll value of one notch of a mouse wheel.
const WheelNotch = 120

// Mouse is the ready-made relative mouse of WinUHidDevs.dll: five buttons, vertical and
// horizontal wheel. It exists until Close is called or the process ends.
type Mouse struct {
	handle uintptr
}

// NewMouse creates a virtual mouse with the given identifiers. Use identifiers that are yours.
// A zero vendor ID is refused: the library would then present the device with the identifiers
// of a real Microsoft mouse, which a product must not do.
func NewMouse(vendorID, productID uint16) (*Mouse, error) {
	if vendorID == 0 {
		return nil, errors.New("winuhid: a vendor ID is required")
	}
	info := &presetDeviceInfo{VendorID: vendorID, ProductID: productID}
	handle, _, lastError := procMouseCreate.Call(uintptr(unsafe.Pointer(info)))
	if handle == 0 {
		return nil, callError("WinUHidMouseCreate", lastError)
	}
	return &Mouse{handle: handle}, nil
}

// Move moves the pointer by a relative amount. Like a physical mouse, the distance on screen
// also depends on the user's pointer speed and acceleration settings.
func (m *Mouse) Move(dx, dy int16) error {
	ok, _, lastError := procMouseReportMotion.Call(m.handle, uintptr(dx), uintptr(dy))
	if ok == 0 {
		return callError("WinUHidMouseReportMotion", lastError)
	}
	return nil
}

// Button presses (down = true) or releases a button. Other buttons keep their state.
func (m *Mouse) Button(button MouseButton, down bool) error {
	ok, _, lastError := procMouseReportButton.Call(m.handle, uintptr(button), boolArg(down))
	if ok == 0 {
		return callError("WinUHidMouseReportButton", lastError)
	}
	return nil
}

// Scroll turns the wheel. Use multiples of WheelNotch: positive scrolls up (or right when
// horizontal is true), negative scrolls down (or left).
func (m *Mouse) Scroll(value int16, horizontal bool) error {
	ok, _, lastError := procMouseReportScroll.Call(m.handle, uintptr(value), boolArg(horizontal))
	if ok == 0 {
		return callError("WinUHidMouseReportScroll", lastError)
	}
	return nil
}

// Close removes the mouse from Windows. The Mouse must not be used afterwards.
func (m *Mouse) Close() {
	if m.handle != 0 {
		procMouseDestroy.Call(m.handle)
		m.handle = 0
	}
}
