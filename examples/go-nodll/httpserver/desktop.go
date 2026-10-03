//go:build windows

package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

// Reading the screen size and the pointer position only works from inside the session that
// owns the screen (the "console session"). A service running as SYSTEM lives in its own
// session and would read its own, unrelated values. So when this program is not in the
// console session, it starts a short-lived copy of itself there, which reads the values and
// hands them back. That needs the rights of SYSTEM; an ordinary elevated process cannot do it.

var (
	kernel32 = syscall.NewLazyDLL("kernel32.dll")
	user32   = syscall.NewLazyDLL("user32.dll")
	advapi32 = syscall.NewLazyDLL("advapi32.dll")

	procWTSGetActiveConsoleSessionId = kernel32.NewProc("WTSGetActiveConsoleSessionId")
	procProcessIdToSessionId         = kernel32.NewProc("ProcessIdToSessionId")
	procGetSystemMetrics             = user32.NewProc("GetSystemMetrics")
	procGetCursorPos                 = user32.NewProc("GetCursorPos")
	procSetProcessDPIAware           = user32.NewProc("SetProcessDPIAware")
	procDuplicateTokenEx             = advapi32.NewProc("DuplicateTokenEx")
	procSetTokenInformation          = advapi32.NewProc("SetTokenInformation")
)

const noSession = 0xFFFFFFFF

// desktopInfo is what can be seen from inside the console session.
type desktopInfo struct {
	Width, Height int  // primary screen, in physical pixels
	X, Y          int  // pointer position
	HasPointer    bool // false when the pointer cannot be read (for example on the lock screen)
	Source        string
}

// ownSessionID returns the session this process runs in.
func ownSessionID() uint32 {
	var session uint32
	procProcessIdToSessionId.Call(uintptr(os.Getpid()), uintptr(unsafe.Pointer(&session)))
	return session
}

// consoleSessionID returns the session attached to the physical screen, or noSession.
func consoleSessionID() uint32 {
	session, _, _ := procWTSGetActiveConsoleSessionId.Call()
	return uint32(session)
}

var dpiAware sync.Once

// readDesktopDirect reads the values in this process's own session.
func readDesktopDirect() desktopInfo {
	// Without this, Windows reports scaled-down numbers on screens that use display scaling.
	dpiAware.Do(func() { procSetProcessDPIAware.Call() })

	width, _, _ := procGetSystemMetrics.Call(0)  // SM_CXSCREEN
	height, _, _ := procGetSystemMetrics.Call(1) // SM_CYSCREEN
	info := desktopInfo{Width: int(width), Height: int(height), Source: "read directly"}

	var position struct{ X, Y int32 }
	if ok, _, _ := procGetCursorPos.Call(uintptr(unsafe.Pointer(&position))); ok != 0 {
		info.X, info.Y, info.HasPointer = int(position.X), int(position.Y), true
	}
	return info
}

// writeDesktopInfo is what the short-lived copy does: read, write to the given file, exit.
func writeDesktopInfo(path string) error {
	info := readDesktopDirect()
	pointer := 0
	if info.HasPointer {
		pointer = 1
	}
	text := fmt.Sprintf("%d %d %d %d %d\n", info.Width, info.Height, info.X, info.Y, pointer)
	return os.WriteFile(path, []byte(text), 0o600)
}

var (
	desktopMu    sync.Mutex
	desktopCache desktopInfo
	desktopAt    time.Time
)

// queryDesktop returns the screen size and pointer position of the console session.
// maxAge allows a recent answer to be reused, which matters when each answer costs a process start.
func queryDesktop(maxAge time.Duration) (desktopInfo, error) {
	own, console := ownSessionID(), consoleSessionID()
	if console == noSession {
		return desktopInfo{}, errors.New("no session is attached to the screen right now")
	}
	if own == console {
		return readDesktopDirect(), nil
	}

	desktopMu.Lock()
	defer desktopMu.Unlock()
	if maxAge > 0 && time.Since(desktopAt) < maxAge {
		return desktopCache, nil
	}
	info, err := queryDesktopFromSession(console)
	if err != nil {
		return desktopInfo{}, fmt.Errorf("this process runs in session %d, the screen belongs to session %d, and reading it from there failed: %w", own, console, err)
	}
	desktopCache, desktopAt = info, time.Now()
	return info, nil
}

// queryDesktopFromSession starts a copy of this program inside the given session and reads its answer.
func queryDesktopFromSession(session uint32) (desktopInfo, error) {
	const (
		tokenAssignPrimary   = 0x0001
		tokenDuplicate       = 0x0002
		tokenQuery           = 0x0008
		tokenAdjustDefault   = 0x0080
		tokenAdjustSessionID = 0x0100
		maximumAllowed       = 0x02000000
		securityImpersonate  = 2
		tokenPrimary         = 1
		tokenSessionID       = 12 // TOKEN_INFORMATION_CLASS: TokenSessionId
		createNoWindow       = 0x08000000
		waitObject0          = 0
	)

	exe, err := os.Executable()
	if err != nil {
		return desktopInfo{}, err
	}
	out := filepath.Join(os.TempDir(), fmt.Sprintf("winuhid-http-desktop-%d-%d.txt", os.Getpid(), time.Now().UnixNano()))
	defer os.Remove(out)

	// A copy of our own token, re-targeted at the other session.
	var own syscall.Token
	access := uint32(tokenAssignPrimary | tokenDuplicate | tokenQuery | tokenAdjustDefault | tokenAdjustSessionID)
	if err := syscall.OpenProcessToken(syscall.Handle(^uintptr(0)), access, &own); err != nil { // ^0 is the current process
		return desktopInfo{}, fmt.Errorf("open own token: %w", err)
	}
	defer own.Close()

	var copyOfToken syscall.Token
	if ok, _, callErr := procDuplicateTokenEx.Call(uintptr(own), maximumAllowed, 0, securityImpersonate, tokenPrimary, uintptr(unsafe.Pointer(&copyOfToken))); ok == 0 {
		return desktopInfo{}, fmt.Errorf("duplicate token: %w", callErr)
	}
	defer copyOfToken.Close()

	if ok, _, callErr := procSetTokenInformation.Call(uintptr(copyOfToken), tokenSessionID, uintptr(unsafe.Pointer(&session)), unsafe.Sizeof(session)); ok == 0 {
		return desktopInfo{}, fmt.Errorf("point token at session %d (only SYSTEM may do this): %w", session, callErr)
	}

	commandLine, err := syscall.UTF16PtrFromString(fmt.Sprintf(`"%s" -desktop-info "%s"`, exe, out))
	if err != nil {
		return desktopInfo{}, err
	}
	desktop, _ := syscall.UTF16PtrFromString(`winsta0\default`) // the interactive desktop of that session
	startup := syscall.StartupInfo{Desktop: desktop}
	startup.Cb = uint32(unsafe.Sizeof(startup))
	var process syscall.ProcessInformation
	if err := syscall.CreateProcessAsUser(copyOfToken, nil, commandLine, nil, nil, false, createNoWindow, nil, nil, &startup, &process); err != nil {
		return desktopInfo{}, fmt.Errorf("start helper in session %d: %w", session, err)
	}
	defer syscall.CloseHandle(process.Thread)
	defer syscall.CloseHandle(process.Process)

	if event, _ := syscall.WaitForSingleObject(process.Process, 3000); event != waitObject0 {
		syscall.TerminateProcess(process.Process, 1)
		return desktopInfo{}, errors.New("the helper did not answer within 3 seconds")
	}

	data, err := os.ReadFile(out)
	if err != nil {
		return desktopInfo{}, fmt.Errorf("the helper left no answer: %w", err)
	}
	var info desktopInfo
	var pointer int
	if _, err := fmt.Sscanf(string(data), "%d %d %d %d %d", &info.Width, &info.Height, &info.X, &info.Y, &pointer); err != nil {
		return desktopInfo{}, fmt.Errorf("the helper's answer is unreadable: %w", err)
	}
	info.HasPointer = pointer == 1
	info.Source = fmt.Sprintf("read by a helper started in session %d", session)
	return info, nil
}
