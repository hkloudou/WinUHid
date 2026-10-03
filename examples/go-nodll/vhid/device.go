//go:build windows

// Package vhid creates virtual HID input devices (a keyboard and a mouse) by talking to the
// WinUHid driver directly. It needs nothing but the installed driver: no WinUHid.dll, no
// WinUHidDevs.dll, no C compiler, and only the Go standard library.
//
// It covers input-only devices, which is all a keyboard and a mouse need: the program sends
// input reports to Windows and never has to answer requests coming back from it.
//
// The driver only lets administrators (and SYSTEM) create devices, so the calling process
// must run elevated. A device exists for as long as it is open: Close it, or let the process
// end, and it disappears from Windows.
package vhid

import (
	"errors"
	"fmt"
	"syscall"
	"unsafe"
)

// The driver's control device and the commands it understands. These mirror
// "WinUHid Driver/Public.h" and must be kept in step with it.
const (
	controlDevicePath = `\\.\WinUHid`

	// interfaceVersion is the version of the driver interface this package speaks.
	interfaceVersion = 1

	fileDeviceUnknown = 0x22
	accessAny         = 0 // FILE_ANY_ACCESS
	accessWrite       = 2 // FILE_WRITE_DATA
)

// controlCode builds a device control code the way the CTL_CODE macro does
// (buffered transfer, function numbers starting at 0x800).
func controlCode(function, access uint32) uint32 {
	return fileDeviceUnknown<<16 | access<<14 | (0x800+function)<<2
}

var (
	ioctlSetDeviceInfo       = controlCode(0, accessWrite) // input: deviceInfo
	ioctlSetReportDescriptor = controlCode(1, accessWrite) // input: the raw report descriptor
	ioctlCreateDevice        = controlCode(4, accessWrite) // no data
	ioctlStartDevice         = controlCode(5, accessWrite) // no data
	ioctlGetInterfaceVersion = controlCode(9, accessAny)   // output: uint32
)

// guid has the layout of the Windows GUID structure.
type guid struct {
	Data1 uint32
	Data2 uint16
	Data3 uint16
	Data4 [8]byte
}

// deviceInfo mirrors WINUHID_DEVICE_INFO.
type deviceInfo struct {
	InterfaceVersion uint32
	SupportedEvents  uint32 // requests from Windows the program wants to answer; 0 = input-only
	VendorID         uint16
	ProductID        uint16
	VersionNumber    uint16
	ContainerID      guid // offset 16
}

// Layout checks: these fail to compile if deviceInfo is not laid out as the driver expects.
var (
	_ = [1]struct{}{}[unsafe.Offsetof(deviceInfo{}.VendorID)-8]
	_ = [1]struct{}{}[unsafe.Offsetof(deviceInfo{}.ContainerID)-16]
	_ = [1]struct{}{}[unsafe.Sizeof(deviceInfo{})-32]
)

// Errors that say why the driver could not be reached. Test with errors.Is.
var (
	// ErrDriverNotInstalled means the WinUHid driver is not installed on this machine.
	ErrDriverNotInstalled = errors.New("the WinUHid driver is not installed")
	// ErrAccessDenied means the process is not elevated; only administrators may create devices.
	ErrAccessDenied = errors.New("access denied: only administrators may create virtual devices")
)

// wrap names the failed step and maps the two common causes to the errors above.
func wrap(step string, err error) error {
	var errno syscall.Errno
	if errors.As(err, &errno) {
		switch errno {
		case syscall.ERROR_FILE_NOT_FOUND, syscall.ERROR_PATH_NOT_FOUND:
			return fmt.Errorf("%s: %w", step, ErrDriverNotInstalled)
		case syscall.ERROR_ACCESS_DENIED:
			return fmt.Errorf("%s: %w", step, ErrAccessDenied)
		}
	}
	return fmt.Errorf("%s: %w", step, err)
}

// openControlDevice opens the driver's control device. Each open handle can carry one virtual device.
func openControlDevice() (syscall.Handle, error) {
	path, err := syscall.UTF16PtrFromString(controlDevicePath)
	if err != nil {
		return syscall.InvalidHandle, err
	}
	handle, err := syscall.CreateFile(path,
		syscall.GENERIC_READ|syscall.GENERIC_WRITE,
		syscall.FILE_SHARE_READ|syscall.FILE_SHARE_WRITE|syscall.FILE_SHARE_DELETE,
		nil, syscall.OPEN_EXISTING, 0, 0)
	if err != nil {
		return syscall.InvalidHandle, wrap("open "+controlDevicePath, err)
	}
	return handle, nil
}

// control sends one command, with optional input data, to the driver.
func control(handle syscall.Handle, code uint32, input []byte) error {
	var in *byte
	if len(input) > 0 {
		in = &input[0]
	}
	var returned uint32
	return syscall.DeviceIoControl(handle, code, in, uint32(len(input)), nil, 0, &returned, nil)
}

// DriverInterfaceVersion returns the interface version of the installed driver (currently 1).
// It fails when the driver is not installed or the process is not elevated.
func DriverInterfaceVersion() (uint32, error) {
	handle, err := openControlDevice()
	if err != nil {
		return 0, err
	}
	defer syscall.CloseHandle(handle)

	var version, returned uint32
	err = syscall.DeviceIoControl(handle, ioctlGetInterfaceVersion, nil, 0,
		(*byte)(unsafe.Pointer(&version)), uint32(unsafe.Sizeof(version)), &returned, nil)
	if err != nil {
		return 0, wrap("query driver interface version", err)
	}
	return version, nil
}

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

// Device is a virtual, input-only HID device. Keyboard and Mouse are built on it; use it
// directly to make any other input-only device from a report descriptor.
type Device struct {
	handle syscall.Handle
}

// CreateDevice creates the device and makes it appear in Windows.
//
// Windows needs a moment to set up a new device. Reports sent before it has finished are
// accepted but have no effect, so wait briefly (or until an effect is seen) before relying on them.
func CreateDevice(config Config) (*Device, error) {
	if config.VendorID == 0 {
		return nil, errors.New("vhid: a vendor ID is required")
	}
	if len(config.ReportDescriptor) == 0 || len(config.ReportDescriptor) > 0xFFFF {
		return nil, errors.New("vhid: the report descriptor must be 1 to 65535 bytes long")
	}

	handle, err := openControlDevice()
	if err != nil {
		return nil, err
	}

	info := deviceInfo{
		InterfaceVersion: interfaceVersion,
		VendorID:         config.VendorID,
		ProductID:        config.ProductID,
		VersionNumber:    config.VersionNumber,
	}
	infoBytes := (*[unsafe.Sizeof(info)]byte)(unsafe.Pointer(&info))[:]

	steps := []struct {
		name  string
		code  uint32
		input []byte
	}{
		{"set device information", ioctlSetDeviceInfo, infoBytes},
		{"set report descriptor", ioctlSetReportDescriptor, config.ReportDescriptor},
		{"create device", ioctlCreateDevice, nil},
		{"start device", ioctlStartDevice, nil},
	}
	for _, step := range steps {
		if err := control(handle, step.code, step.input); err != nil {
			syscall.CloseHandle(handle)
			return nil, wrap(step.name, err)
		}
	}
	return &Device{handle: handle}, nil
}

// SubmitInputReport sends one input report. Its length must be exactly what the report
// descriptor defines; if the descriptor uses report IDs, the ID is the first byte.
func (d *Device) SubmitInputReport(report []byte) error {
	if d.handle == syscall.InvalidHandle {
		return errors.New("vhid: the device is closed")
	}
	if len(report) == 0 {
		return errors.New("vhid: empty report")
	}
	var written uint32
	if err := syscall.WriteFile(d.handle, report, &written, nil); err != nil {
		return wrap("submit input report", err)
	}
	return nil
}

// Close removes the device from Windows. The Device must not be used afterwards.
func (d *Device) Close() error {
	if d.handle == syscall.InvalidHandle {
		return nil
	}
	err := syscall.CloseHandle(d.handle)
	d.handle = syscall.InvalidHandle
	return err
}
