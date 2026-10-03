//go:build windows

// Command winuhid-sample shows how a Go program drives virtual input devices through
// WinUHid.dll and WinUHidDevs.dll, and checks that the input really arrives in Windows.
//
// It creates a mouse (the ready-made one from WinUHidDevs.dll) and a keyboard (built with the
// general interface of WinUHid.dll), uses them briefly, and removes them again.
//
// Run it from an elevated prompt on a machine where the WinUHid driver is installed.
package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"time"
	"unsafe"

	"github.com/hkloudou/WinUHid/examples/go/winuhid"
)

// Placeholder identifiers for testing. A product must use identifiers of its own.
const (
	testVendorID          = 0x1234
	testMouseProductID    = 0x5678
	testKeyboardProductID = 0x5679
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
	dllDir := flag.String("dll-dir", "", "folder with WinUHid.dll and WinUHidDevs.dll (default: next to this program, or the kit's lib folder)")
	typeText := flag.String("type", "", "text to type with the virtual keyboard after a 5 second countdown (US keyboard layout)")
	click := flag.Bool("click", false, "also press and release the left mouse button where the pointer is")
	strict := flag.Bool("strict", false, "fail when input cannot be observed arriving (for automated tests in the console session)")
	flag.Parse()

	r := &report{strict: *strict}
	run(r, *dllDir, *typeText, *click)

	fmt.Println()
	if r.failed {
		fmt.Println("RESULT: FAILED")
		os.Exit(1)
	}
	fmt.Println("RESULT: OK")
}

func run(r *report, dllDir, typeText string, click bool) {
	dir, err := findLibraries(dllDir)
	if err != nil {
		r.fail("%v", err)
		return
	}
	if err := winuhid.Load(dir); err != nil {
		r.fail("%v", err)
		return
	}
	r.info("Libraries loaded from %s", dir)

	version, err := winuhid.DriverInterfaceVersion()
	switch {
	case errors.Is(err, winuhid.ErrDriverNotInstalled):
		r.fail("The WinUHid driver is not installed on this machine. Run install.cmd first.")
		return
	case errors.Is(err, winuhid.ErrAccessDenied):
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
	keyboardDemo(r, typeText)
}

// findLibraries returns the folder that holds the two DLLs.
func findLibraries(dllDir string) (string, error) {
	candidates := []string{dllDir}
	if dllDir == "" {
		candidates = nil
		if exe, err := os.Executable(); err == nil {
			exeDir := filepath.Dir(exe)
			candidates = append(candidates, exeDir, filepath.Join(exeDir, "..", "..", "lib"))
		}
		candidates = append(candidates, "lib", ".")
	}
	for _, dir := range candidates {
		if _, err := os.Stat(filepath.Join(dir, "WinUHid.dll")); err != nil {
			continue
		}
		if _, err := os.Stat(filepath.Join(dir, "WinUHidDevs.dll")); err != nil {
			continue
		}
		return filepath.Abs(dir)
	}
	return "", errors.New("WinUHid.dll and WinUHidDevs.dll were not found; pass their folder with -dll-dir")
}

// mouseDemo uses the ready-made mouse of WinUHidDevs.dll.
func mouseDemo(r *report, click bool) {
	mouse, err := winuhid.NewMouse(testVendorID, testMouseProductID)
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
	if err := mouse.Scroll(winuhid.WheelNotch, false); err != nil {
		r.fail("Mouse wheel was rejected: %v", err)
		return
	}
	time.Sleep(100 * time.Millisecond)
	if err := mouse.Scroll(-winuhid.WheelNotch, false); err != nil {
		r.fail("Mouse wheel was rejected: %v", err)
		return
	}
	r.pass("Mouse wheel reports accepted (one notch up, one notch down).")

	if !click {
		return
	}
	if err := mouse.Button(winuhid.ButtonLeft, true); err != nil {
		r.fail("Mouse button was rejected: %v", err)
		return
	}
	time.Sleep(200 * time.Millisecond)
	leftDown, rightDown := keyIsDown(vkLeftButton), keyIsDown(vkRightButton)
	if err := mouse.Button(winuhid.ButtonLeft, false); err != nil {
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

// keyboardDemo uses a keyboard built with the general interface of WinUHid.dll.
func keyboardDemo(r *report, typeText string) {
	keyboard, err := winuhid.NewKeyboard(testVendorID, testKeyboardProductID)
	if err != nil {
		r.fail("Virtual keyboard could not be created: %v", err)
		return
	}
	defer keyboard.Close()
	defer keyboard.ReleaseAll()
	r.pass("Virtual keyboard created.")

	// Same idea as for the mouse: press Left Shift (which types nothing) until Windows shows it.
	alreadyHeld, seenDown, seenUp := false, false, false
	for attempt := 0; attempt < 10 && !seenDown; attempt++ {
		time.Sleep(500 * time.Millisecond)
		if alreadyHeld = keyIsDown(vkLeftShift); alreadyHeld {
			break
		}
		if err := keyboard.KeyDown(winuhid.KeyLeftShift); err != nil {
			r.fail("Key press was rejected: %v", err)
			return
		}
		time.Sleep(200 * time.Millisecond)
		seenDown = keyIsDown(vkLeftShift)
		if err := keyboard.KeyUp(winuhid.KeyLeftShift); err != nil {
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
		key, shift, ok := winuhid.KeyForRune(character)
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
func tap(keyboard *winuhid.Keyboard, key winuhid.Key, shift bool) error {
	const hold = 15 * time.Millisecond
	if shift {
		if err := keyboard.KeyDown(winuhid.KeyLeftShift); err != nil {
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
		if err := keyboard.KeyUp(winuhid.KeyLeftShift); err != nil {
			return err
		}
		time.Sleep(hold)
	}
	return nil
}
