//go:build windows

// Command winuhid-nodll-sample shows a Go program driving a virtual keyboard and mouse with
// nothing but the installed WinUHid driver: no DLL is shipped or loaded for it. It also checks
// that the input really arrives in Windows.
//
// Run it from an elevated prompt on a machine where the WinUHid driver is installed.
package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"syscall"
	"time"
	"unsafe"

	"github.com/hkloudou/WinUHid/examples/go-nodll/vhid"
)

// Placeholder identifiers for testing. A product must use identifiers of its own.
const (
	testVendorID          = 0x1234
	testMouseProductID    = 0x5688
	testKeyboardProductID = 0x5689
	testAbsoluteProductID = 0x568A
)

// Windows virtual-key codes used to observe what arrived.
const (
	vkLeftButton  = 0x01
	vkRightButton = 0x02
	vkLeftShift   = 0xA0
)

var (
	user32               = syscall.NewLazyDLL("user32.dll")
	procGetCursorPos     = user32.NewProc("GetCursorPos")
	procGetAsyncKeyState = user32.NewProc("GetAsyncKeyState")
	procGetSystemMetrics = user32.NewProc("GetSystemMetrics")
)

type point struct{ X, Y int32 }

// cursorPosition returns where the pointer is; ok is false when this session has no pointer.
func cursorPosition() (p point, ok bool) {
	result, _, _ := procGetCursorPos.Call(uintptr(unsafe.Pointer(&p)))
	return p, result != 0
}

// keyIsDown reports whether Windows currently sees the key or mouse button as held.
func keyIsDown(virtualKey uintptr) bool {
	state, _, _ := procGetAsyncKeyState.Call(virtualKey)
	return state&0x8000 != 0
}

// isRemoteSession reports whether the program runs inside a Remote Desktop session.
func isRemoteSession() bool {
	result, _, _ := procGetSystemMetrics.Call(0x1000) // SM_REMOTESESSION
	return result != 0
}

// report prints the outcome of each check and remembers whether anything failed.
type report struct {
	strict bool // treat "could not observe the input" as a failure
	failed bool
	hint   string
}

func (r *report) info(format string, args ...any) { fmt.Printf("[INFO] "+format+"\n", args...) }
func (r *report) pass(format string, args ...any) { fmt.Printf("[PASS] "+format+"\n", args...) }
func (r *report) fail(format string, args ...any) {
	fmt.Printf("[FAIL] "+format+"\n", args...)
	r.failed = true
}

// unobserved is for input the driver accepted but that could not be seen arriving.
func (r *report) unobserved(format string, args ...any) {
	if r.strict {
		r.fail(format, args...)
		return
	}
	fmt.Printf("[WARN] "+format+r.hint+"\n", args...)
}

func main() {
	typeText := flag.String("type", "", "text to type with the virtual keyboard after a 5 second countdown (US keyboard layout)")
	click := flag.Bool("click", false, "also press and release the left mouse button where the pointer is")
	strict := flag.Bool("strict", false, "fail when input cannot be observed arriving (for automated tests in the console session)")
	flag.Parse()

	r := &report{strict: *strict}
	run(r, *typeText, *click)

	fmt.Println()
	if r.failed {
		fmt.Println("RESULT: FAILED")
		os.Exit(1)
	}
	fmt.Println("RESULT: OK")
}

func run(r *report, typeText string, click bool) {
	r.info("Talking to the driver directly; no WinUHid DLL is used.")

	version, err := vhid.DriverInterfaceVersion()
	switch {
	case errors.Is(err, vhid.ErrDriverNotInstalled):
		r.fail("The WinUHid driver is not installed on this machine. Run install.cmd first.")
		return
	case errors.Is(err, vhid.ErrAccessDenied):
		r.fail("Access denied. Only administrators may create virtual devices: run this from an elevated prompt.")
		return
	case err != nil:
		r.fail("%v", err)
		return
	}
	r.pass("Driver reachable, interface version %d.", version)

	// Virtual devices behave like hardware plugged into the machine: their input goes to the
	// physical console session. A Remote Desktop session has its own input path and does not see it.
	if isRemoteSession() {
		r.info("This is a Remote Desktop session: devices can be created, but their input goes to the")
		r.info("physical console, not to this session, so it cannot be observed from here.")
		r.hint = " Expected in a Remote Desktop session."
	}

	mouseDemo(r, click)
	absoluteMouseDemo(r, click)
	keyboardDemo(r, typeText)
}

// screenSize returns the size of the primary screen in pixels.
func screenSize() (width, height int) {
	w, _, _ := procGetSystemMetrics.Call(0) // SM_CXSCREEN
	h, _, _ := procGetSystemMetrics.Call(1) // SM_CYSCREEN
	return int(w), int(h)
}

// near reports whether two positions are at most tolerance pixels apart on each axis.
func near(a, b point, tolerance int32) bool {
	dx, dy := a.X-b.X, a.Y-b.Y
	return dx >= -tolerance && dx <= tolerance && dy >= -tolerance && dy <= tolerance
}

// absoluteMouseDemo places the pointer at chosen pixels and reads back where it ended up.
func absoluteMouseDemo(r *report, click bool) {
	pointer, err := vhid.NewAbsoluteMouse(testVendorID, testAbsoluteProductID)
	if err != nil {
		r.fail("Virtual absolute mouse could not be created: %v", err)
		return
	}
	defer pointer.Close()
	r.pass("Virtual absolute mouse created.")

	width, height := screenSize()
	original, observable := cursorPosition()
	if !observable || width <= 0 || height <= 0 {
		if err := pointer.MoveTo(vhid.AbsoluteMax/2, vhid.AbsoluteMax/2); err != nil {
			r.fail("Absolute position was rejected: %v", err)
			return
		}
		r.unobserved("Absolute position accepted, but this session has no pointer to observe.")
		return
	}
	r.info("Primary screen: %d x %d pixels. The pointer will visit a few places and return.", width, height)

	targets := []point{
		{int32(width / 4), int32(height / 4)},
		{int32(3 * width / 4), int32(3 * height / 4)},
		{int32(width / 2), int32(height / 2)},
		{123, 234},
	}
	// The first target must differ from where the pointer already is, or reaching it proves nothing.
	if near(original, targets[0], 2) {
		targets[0], targets[1] = targets[1], targets[0]
	}

	place := func(target point) (point, error) {
		if err := pointer.MoveToPixel(int(target.X), int(target.Y), width, height); err != nil {
			return point{}, err
		}
		time.Sleep(200 * time.Millisecond)
		actual, _ := cursorPosition()
		return actual, nil
	}

	// Windows needs a moment to set up a new device: repeat the first placement until it shows.
	var actual point
	ready := false
	for attempt := 0; attempt < 10 && !ready; attempt++ {
		time.Sleep(500 * time.Millisecond)
		if actual, err = place(targets[0]); err != nil {
			r.fail("Absolute position was rejected: %v", err)
			return
		}
		ready = near(actual, targets[0], 2)
	}
	if !ready && actual == original {
		r.unobserved("Absolute positions accepted, but the pointer did not move.")
		return
	}

	exact := true
	summary := ""
	for i, target := range targets {
		if i > 0 { // the first one was placed above
			if actual, err = place(target); err != nil {
				r.fail("Absolute position was rejected: %v", err)
				return
			}
		}
		if !near(actual, target, 1) {
			exact = false
		}
		summary += fmt.Sprintf(" (%d,%d)->(%d,%d)", target.X, target.Y, actual.X, actual.Y)
	}
	if exact {
		r.pass("Pointer placed where asked, wanted->got:%s.", summary)
	} else {
		r.fail("Pointer did not land where asked, wanted->got:%s.", summary)
	}

	if click {
		centre := targets[2]
		if actual, err = place(centre); err != nil {
			r.fail("Absolute position was rejected: %v", err)
			return
		}
		if err := pointer.Button(vhid.ButtonLeft, true); err != nil {
			r.fail("Button on the absolute mouse was rejected: %v", err)
			return
		}
		time.Sleep(200 * time.Millisecond)
		leftDown, rightDown := keyIsDown(vkLeftButton), keyIsDown(vkRightButton)
		held, _ := cursorPosition()
		if err := pointer.Button(vhid.ButtonLeft, false); err != nil {
			r.fail("Button on the absolute mouse was rejected: %v", err)
			return
		}
		time.Sleep(200 * time.Millisecond)
		leftReleased := !keyIsDown(vkLeftButton)
		switch {
		case leftDown && !rightDown && leftReleased && near(held, centre, 1):
			r.pass("Left click at (%d,%d) really arrived, with the pointer still there.", centre.X, centre.Y)
		case leftDown && !rightDown && leftReleased:
			r.fail("Left click arrived, but the pointer was at (%d,%d) instead of (%d,%d).", held.X, held.Y, centre.X, centre.Y)
		default:
			r.unobserved("Click on the absolute mouse accepted, but Windows did not show it (down seen=%v, up seen=%v).", leftDown, leftReleased)
		}
	}

	_, _ = place(original) // put the pointer back
}

func mouseDemo(r *report, click bool) {
	mouse, err := vhid.NewMouse(testVendorID, testMouseProductID)
	if err != nil {
		r.fail("Virtual mouse could not be created: %v", err)
		return
	}
	defer mouse.Close()
	r.pass("Virtual mouse created.")

	// Windows needs a moment to set up a new device, and input sent before that is lost.
	// So: nudge the pointer and look whether it moved, a few times if necessary.
	observable, moved := true, false
	var before, after point
	for attempt := 0; attempt < 10 && !moved; attempt++ {
		time.Sleep(500 * time.Millisecond)
		var ok bool
		if before, ok = cursorPosition(); !ok {
			observable = false
			break
		}
		dx := int16(40)
		if before.X > 300 {
			dx = -40
		}
		if err := mouse.Move(dx, 0); err != nil {
			r.fail("Mouse motion was rejected: %v", err)
			return
		}
		time.Sleep(200 * time.Millisecond)
		after, _ = cursorPosition()
		if moved = after.X != before.X; moved {
			_ = mouse.Move(-dx, 0) // back to where it was
		}
	}
	switch {
	case moved:
		r.pass("Pointer really moved: x %d -> %d.", before.X, after.X)
	case !observable:
		r.unobserved("Mouse motion accepted, but this session has no pointer to observe.")
	default:
		r.unobserved("Mouse motion accepted, but the pointer did not move.")
	}

	// Something to watch: a small square, then the wheel one notch up and back down.
	r.info("Watch the pointer: it draws a small square.")
	for _, side := range [][2]int16{{8, 0}, {0, 8}, {-8, 0}, {0, -8}} {
		for step := 0; step < 12; step++ {
			if err := mouse.Move(side[0], side[1]); err != nil {
				r.fail("Mouse motion was rejected: %v", err)
				return
			}
			time.Sleep(15 * time.Millisecond)
		}
	}
	if err := mouse.Scroll(1); err != nil {
		r.fail("Mouse wheel was rejected: %v", err)
		return
	}
	time.Sleep(100 * time.Millisecond)
	if err := mouse.Scroll(-1); err != nil {
		r.fail("Mouse wheel was rejected: %v", err)
		return
	}
	r.pass("Mouse wheel reports accepted (one notch up, one notch down).")

	if !click {
		return
	}
	if err := mouse.Button(vhid.ButtonLeft, true); err != nil {
		r.fail("Mouse button was rejected: %v", err)
		return
	}
	time.Sleep(200 * time.Millisecond)
	leftDown, rightDown := keyIsDown(vkLeftButton), keyIsDown(vkRightButton)
	if err := mouse.Button(vhid.ButtonLeft, false); err != nil {
		r.fail("Mouse button was rejected: %v", err)
		return
	}
	time.Sleep(200 * time.Millisecond)
	leftReleased := !keyIsDown(vkLeftButton)
	switch {
	case leftDown && !rightDown && leftReleased:
		r.pass("Left button press really arrived, as the left button.")
	case rightDown:
		r.fail("The left button press arrived as the RIGHT button.")
	default:
		r.unobserved("Left button reports accepted, but Windows did not show the press (down seen=%v, up seen=%v).", leftDown, leftReleased)
	}
}

func keyboardDemo(r *report, typeText string) {
	keyboard, err := vhid.NewKeyboard(testVendorID, testKeyboardProductID)
	if err != nil {
		r.fail("Virtual keyboard could not be created: %v", err)
		return
	}
	defer keyboard.Close()
	r.pass("Virtual keyboard created.")

	// Same idea as for the mouse: press Left Shift (which types nothing) until Windows shows it.
	alreadyHeld, seenDown, seenUp := false, false, false
	for attempt := 0; attempt < 10 && !seenDown; attempt++ {
		time.Sleep(500 * time.Millisecond)
		if alreadyHeld = keyIsDown(vkLeftShift); alreadyHeld {
			break
		}
		if err := keyboard.KeyDown(vhid.KeyLeftShift); err != nil {
			r.fail("Key press was rejected: %v", err)
			return
		}
		time.Sleep(200 * time.Millisecond)
		seenDown = keyIsDown(vkLeftShift)
		if err := keyboard.KeyUp(vhid.KeyLeftShift); err != nil {
			r.fail("Key release was rejected: %v", err)
			return
		}
		time.Sleep(200 * time.Millisecond)
		seenUp = !keyIsDown(vkLeftShift)
	}
	switch {
	case seenDown && seenUp:
		r.pass("Key press really arrived: Windows saw Left Shift go down and up.")
	case alreadyHeld:
		r.unobserved("Left Shift is being held on a real keyboard, so the virtual key press could not be observed.")
	default:
		r.unobserved("Key reports accepted, but Windows did not show the key (down seen=%v, up seen=%v).", seenDown, seenUp)
	}

	if typeText == "" {
		return
	}
	r.info("Typing %q in 5 seconds. Click into the window that should receive it.", typeText)
	for seconds := 5; seconds > 0; seconds-- {
		fmt.Printf("       %d...\n", seconds)
		time.Sleep(time.Second)
	}
	skipped := 0
	for _, character := range typeText {
		key, shift, ok := vhid.KeyForRune(character)
		if !ok {
			skipped++
			continue
		}
		if err := tap(keyboard, key, shift); err != nil {
			r.fail("Typing was rejected: %v", err)
			return
		}
	}
	r.pass("Typed %d characters (%d skipped: not on a US keyboard).", len([]rune(typeText))-skipped, skipped)
}

// tap presses and releases one key, holding Left Shift around it when asked.
func tap(keyboard *vhid.Keyboard, key vhid.Key, shift bool) error {
	const hold = 15 * time.Millisecond
	if shift {
		if err := keyboard.KeyDown(vhid.KeyLeftShift); err != nil {
			return err
		}
		time.Sleep(hold)
	}
	if err := keyboard.KeyDown(key); err != nil {
		return err
	}
	time.Sleep(hold)
	if err := keyboard.KeyUp(key); err != nil {
		return err
	}
	time.Sleep(hold)
	if shift {
		if err := keyboard.KeyUp(vhid.KeyLeftShift); err != nil {
			return err
		}
		time.Sleep(hold)
	}
	return nil
}
