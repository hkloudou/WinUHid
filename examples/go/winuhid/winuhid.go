//go:build windows

// Package winuhid is a small Go binding for WinUHid.dll and WinUHidDevs.dll.
//
// It uses only the standard library and needs no C compiler: the DLLs are loaded at run time.
//
//   - WinUHid.dll is the general interface: describe any HID device with a report descriptor,
//     then feed it input reports. See Device, and Keyboard for a device built that way.
//   - WinUHidDevs.dll offers ready-made devices on top of it. See Mouse.
//
// The driver only lets administrators (and SYSTEM) create devices, so the calling process
// must run elevated.
package winuhid

import (
	"errors"
	"fmt"
	"path/filepath"
	"syscall"
	"unsafe"
)

var (
	baseDLL *syscall.DLL // WinUHid.dll
	devsDLL *syscall.DLL // WinUHidDevs.dll

	procGetDriverInterfaceVersion *syscall.Proc
	procCreateDevice              *syscall.Proc
	procStartDevice               *syscall.Proc
	procSubmitInputReport         *syscall.Proc
	procDestroyDevice             *syscall.Proc

	procMouseCreate       *syscall.Proc
	procMouseReportMotion *syscall.Proc
	procMouseReportButton *syscall.Proc
	procMouseReportScroll *syscall.Proc
	procMouseDestroy      *syscall.Proc
)

// Load loads WinUHid.dll and WinUHidDevs.dll from dir. Call it once before anything else.
func Load(dir string) error {
	if baseDLL != nil {
		return nil
	}
	dir, err := filepath.Abs(dir)
	if err != nil {
		return err
	}

	// WinUHid.dll first: WinUHidDevs.dll depends on it, and Windows resolves that dependency
	// to the copy that is already loaded, wherever the program itself lives.
	base, err := syscall.LoadDLL(filepath.Join(dir, "WinUHid.dll"))
	if err != nil {
		return fmt.Errorf("load WinUHid.dll: %w", err)
	}
	devs, err := syscall.LoadDLL(filepath.Join(dir, "WinUHidDevs.dll"))
	if err != nil {
		return fmt.Errorf("load WinUHidDevs.dll: %w", err)
	}

	find := func(dll *syscall.DLL, name string) *syscall.Proc {
		proc, findErr := dll.FindProc(name)
		if findErr != nil && err == nil {
			err = findErr
		}
		return proc
	}
	procGetDriverInterfaceVersion = find(base, "WinUHidGetDriverInterfaceVersion")
	procCreateDevice = find(base, "WinUHidCreateDevice")
	procStartDevice = find(base, "WinUHidStartDevice")
	procSubmitInputReport = find(base, "WinUHidSubmitInputReport")
	procDestroyDevice = find(base, "WinUHidDestroyDevice")
	procMouseCreate = find(devs, "WinUHidMouseCreate")
	procMouseReportMotion = find(devs, "WinUHidMouseReportMotion")
	procMouseReportButton = find(devs, "WinUHidMouseReportButton")
	procMouseReportScroll = find(devs, "WinUHidMouseReportScroll")
	procMouseDestroy = find(devs, "WinUHidMouseDestroy")
	if err != nil {
		return err
	}

	baseDLL, devsDLL = base, devs
	return nil
}

// Errors that say why the driver could not be reached. Test with errors.Is.
var (
	// ErrDriverNotInstalled means the WinUHid driver is not installed on this machine.
	ErrDriverNotInstalled = errors.New("the WinUHid driver is not installed")
	// ErrAccessDenied means the process is not elevated; only administrators may create devices.
	ErrAccessDenied = errors.New("access denied: only administrators may create virtual devices")
)

// callError turns the Windows error of a failed call into a Go error.
func callError(function string, lastError error) error {
	var errno syscall.Errno
	if errors.As(lastError, &errno) {
		switch errno {
		case syscall.ERROR_FILE_NOT_FOUND, syscall.ERROR_PATH_NOT_FOUND:
			return fmt.Errorf("%s: %w", function, ErrDriverNotInstalled)
		case syscall.ERROR_ACCESS_DENIED:
			return fmt.Errorf("%s: %w", function, ErrAccessDenied)
		}
	}
	return fmt.Errorf("%s: %w", function, lastError)
}

// DriverInterfaceVersion returns the interface version of the installed driver (currently 1).
// It fails when the driver is not installed or the process is not elevated.
func DriverInterfaceVersion() (uint32, error) {
	version, _, lastError := procGetDriverInterfaceVersion.Call()
	if version == 0 {
		return 0, callError("WinUHidGetDriverInterfaceVersion", lastError)
	}
	return uint32(version), nil
}

// guid has the layout of the Windows GUID structure.
type guid struct {
	Data1 uint32
	Data2 uint16
	Data3 uint16
	Data4 [8]byte
}

// deviceConfig mirrors WINUHID_DEVICE_CONFIG.
//
// The C structure is packed (no padding), which puts its first pointer at offset 12. Go cannot
// declare packed structures, so this one starts with 4 unused bytes: every field then sits
// exactly 4 bytes later than in C, which happens to be a properly aligned position for each of
// them. The library is handed the address of SupportedEvents, i.e. the C structure's start.
// Keeping real pointer fields (instead of copying addresses into a byte buffer) lets the Go
// runtime see what the structure refers to.
type deviceConfig struct {
	_                      uint32
	SupportedEvents        uint32  // C offset 0
	VendorID               uint16  // C offset 4
	ProductID              uint16  // C offset 6
	VersionNumber          uint16  // C offset 8
	ReportDescriptorLength uint16  // C offset 10
	ReportDescriptor       *byte   // C offset 12
	ContainerID            guid    // C offset 20
	InstanceID             *uint16 // C offset 36
	HardwareIDs            *uint16 // C offset 44
	ReadReportPeriodUs     uint32  // C offset 52
}

// presetDeviceInfo mirrors WINUHID_PRESET_DEVICE_INFO, which uses ordinary alignment.
type presetDeviceInfo struct {
	VendorID      uint16
	ProductID     uint16
	VersionNumber uint16
	ContainerID   guid    // offset 8
	InstanceID    *uint16 // offset 24
	HardwareIDs   *uint16 // offset 32
}

// Layout checks: each line fails to compile if a field is not where the libraries expect it.
var (
	_ = [1]struct{}{}[unsafe.Offsetof(deviceConfig{}.SupportedEvents)-4]
	_ = [1]struct{}{}[unsafe.Offsetof(deviceConfig{}.ReportDescriptor)-4-12]
	_ = [1]struct{}{}[unsafe.Offsetof(deviceConfig{}.ContainerID)-4-20]
	_ = [1]struct{}{}[unsafe.Offsetof(deviceConfig{}.InstanceID)-4-36]
	_ = [1]struct{}{}[unsafe.Offsetof(deviceConfig{}.HardwareIDs)-4-44]
	_ = [1]struct{}{}[unsafe.Offsetof(deviceConfig{}.ReadReportPeriodUs)-4-52]
	_ = [1]struct{}{}[unsafe.Offsetof(presetDeviceInfo{}.ContainerID)-8]
	_ = [1]struct{}{}[unsafe.Offsetof(presetDeviceInfo{}.InstanceID)-24]
	_ = [1]struct{}{}[unsafe.Sizeof(presetDeviceInfo{})-40]
)

// Config describes a device for CreateDevice.
type Config struct {
	// VendorID and ProductID identify the device to Windows and to applications.
	// Use identifiers that are yours; do not present the device as another vendor's product.
	VendorID  uint16
	ProductID uint16
	// VersionNumber is the device's version, shown as its revision. Optional.
	VersionNumber uint16
	// ReportDescriptor is the HID report descriptor: it states what kind of device this is
	// and what its reports look like.
	ReportDescriptor []byte
}

// Device is a virtual HID device made through the general interface of WinUHid.dll.
// It exists until Close is called or the process ends.
type Device struct {
	handle uintptr
}

// CreateDevice creates an input-only device: one that sends reports to Windows and does not
// need to answer requests from it. Call Start before sending reports.
func CreateDevice(config Config) (*Device, error) {
	if len(config.ReportDescriptor) == 0 || len(config.ReportDescriptor) > 0xFFFF {
		return nil, errors.New("winuhid: the report descriptor must be 1 to 65535 bytes long")
	}
	native := &deviceConfig{
		VendorID:               config.VendorID,
		ProductID:              config.ProductID,
		VersionNumber:          config.VersionNumber,
		ReportDescriptorLength: uint16(len(config.ReportDescriptor)),
		ReportDescriptor:       &config.ReportDescriptor[0],
	}
	handle, _, lastError := procCreateDevice.Call(uintptr(unsafe.Pointer(&native.SupportedEvents)))
	if handle == 0 {
		return nil, callError("WinUHidCreateDevice", lastError)
	}
	return &Device{handle: handle}, nil
}

// Start makes the device appear in Windows.
func (d *Device) Start() error {
	ok, _, lastError := procStartDevice.Call(d.handle, 0, 0) // no event callback: input-only
	if ok == 0 {
		return callError("WinUHidStartDevice", lastError)
	}
	return nil
}

// SubmitInputReport sends one input report. Its length must be exactly what the report
// descriptor defines; if the descriptor uses report IDs, the ID is the first byte.
func (d *Device) SubmitInputReport(report []byte) error {
	if len(report) == 0 {
		return errors.New("winuhid: empty report")
	}
	ok, _, lastError := procSubmitInputReport.Call(d.handle, uintptr(unsafe.Pointer(&report[0])), uintptr(len(report)))
	if ok == 0 {
		return callError("WinUHidSubmitInputReport", lastError)
	}
	return nil
}

// Close removes the device from Windows. The Device must not be used afterwards.
func (d *Device) Close() {
	if d.handle != 0 {
		procDestroyDevice.Call(d.handle)
		d.handle = 0
	}
}

func boolArg(value bool) uintptr {
	if value {
		return 1
	}
	return 0
}
