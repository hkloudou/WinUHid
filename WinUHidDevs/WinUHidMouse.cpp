#include "pch.h"
#include "WinUHidMouse.h"

//
// This device emulates a Microsoft Precision Mouse
//

const BYTE k_MouseReportDescriptor[] =
{
	0x05, 0x01,        // Usage Page (Generic Desktop Ctrls)
	0x09, 0x02,        // Usage (Mouse)
	0xA1, 0x01,        // Collection (Application)
	0x05, 0x01,        //   Usage Page (Generic Desktop Ctrls)
	0x09, 0x02,        //   Usage (Mouse)
	0xA1, 0x02,        //   Collection (Logical)
	0x85, 0x01,        //     Report ID (1)
	0x09, 0x01,        //     Usage (Pointer)
	0xA1, 0x00,        //     Collection (Physical)
	0x05, 0x09,        //       Usage Page (Button)
	0x19, 0x01,        //       Usage Minimum (0x01)
	0x29, 0x05,        //       Usage Maximum (0x05)
	0x15, 0x00,        //       Logical Minimum (0)
	0x25, 0x01,        //       Logical Maximum (1)
	0x95, 0x05,        //       Report Count (5)
	0x75, 0x01,        //       Report Size (1)
	0x81, 0x02,        //       Input (Data,Var,Abs,No Wrap,Linear,Preferred State,No Null Position)
	0x95, 0x01,        //       Report Count (1)
	0x75, 0x03,        //       Report Size (3)
	0x81, 0x01,        //       Input (Const,Array,Abs,No Wrap,Linear,Preferred State,No Null Position)
	0x05, 0x01,        //       Usage Page (Generic Desktop Ctrls)
	0x09, 0x30,        //       Usage (X)
	0x09, 0x31,        //       Usage (Y)
	0x95, 0x02,        //       Report Count (2)
	0x75, 0x10,        //       Report Size (16)
	0x16, 0x01, 0x80,  //       Logical Minimum (-32767)
	0x26, 0xFF, 0x7F,  //       Logical Maximum (32767)
	0x81, 0x06,        //       Input (Data,Var,Rel,No Wrap,Linear,Preferred State,No Null Position)
	0xA1, 0x02,        //       Collection (Logical)
	0x85, 0x12,        //         Report ID (18)
	0x09, 0x48,        //         Usage (0x48)
	0x95, 0x01,        //         Report Count (1)
	0x75, 0x02,        //         Report Size (2)
	0x15, 0x00,        //         Logical Minimum (0)
	0x25, 0x01,        //         Logical Maximum (1)
	0x35, 0x01,        //         Physical Minimum (1)
	0x45, 0x78,        //         Physical Maximum (120)
	0xB1, 0x02,        //         Feature (Data,Var,Abs,No Wrap,Linear,Preferred State,No Null Position,Non-volatile)
	0x85, 0x01,        //         Report ID (1)
	0x09, 0x38,        //         Usage (Wheel)
	0x35, 0x00,        //         Physical Minimum (0)
	0x45, 0x00,        //         Physical Maximum (0)
	0x95, 0x01,        //         Report Count (1)
	0x75, 0x10,        //         Report Size (16)
	0x16, 0x01, 0x80,  //         Logical Minimum (-32767)
	0x26, 0xFF, 0x7F,  //         Logical Maximum (32767)
	0x81, 0x06,        //         Input (Data,Var,Rel,No Wrap,Linear,Preferred State,No Null Position)
	0xC0,              //       End Collection
	0xA1, 0x02,        //       Collection (Logical)
	0x85, 0x12,        //         Report ID (18)
	0x09, 0x48,        //         Usage (0x48)
	0x95, 0x01,        //         Report Count (1)
	0x75, 0x02,        //         Report Size (2)
	0x15, 0x00,        //         Logical Minimum (0)
	0x25, 0x01,        //         Logical Maximum (1)
	0x35, 0x01,        //         Physical Minimum (1)
	0x45, 0x78,        //         Physical Maximum (120)
	0xB1, 0x02,        //         Feature (Data,Var,Abs,No Wrap,Linear,Preferred State,No Null Position,Non-volatile)
	0x35, 0x00,        //         Physical Minimum (0)
	0x45, 0x00,        //         Physical Maximum (0)
	0x75, 0x04,        //         Report Size (4)
	0xB1, 0x01,        //         Feature (Const,Array,Abs,No Wrap,Linear,Preferred State,No Null Position,Non-volatile)
	0x85, 0x01,        //         Report ID (1)
	0x05, 0x0C,        //         Usage Page (Consumer)
	0x0A, 0x38, 0x02,  //         Usage (AC Pan)
	0x95, 0x01,        //         Report Count (1)
	0x75, 0x10,        //         Report Size (16)
	0x16, 0x01, 0x80,  //         Logical Minimum (-32767)
	0x26, 0xFF, 0x7F,  //         Logical Maximum (32767)
	0x81, 0x06,        //         Input (Data,Var,Rel,No Wrap,Linear,Preferred State,No Null Position)
	0xC0,              //       End Collection
	0xC0,              //     End Collection
	0xC0,              //   End Collection
	0xC0,              // End Collection
};

const WINUHID_DEVICE_CONFIG k_MouseConfig =
{
	(WINUHID_EVENT_TYPE)(WINUHID_EVENT_GET_FEATURE | WINUHID_EVENT_SET_FEATURE),
	0x045e, // Microsoft
	0x0822, // USB Precision Mouse
	0,
	sizeof(k_MouseReportDescriptor),
	k_MouseReportDescriptor,
	{},
	NULL,
	NULL,
};

#include <pshpack1.h>

#define BASIC_REPORT_ID 0x01
struct BASIC_REPORT {
	UCHAR Id;
	UCHAR Buttons;
	SHORT DeltaX;
	SHORT DeltaY;
	SHORT VScroll;
	SHORT HScroll;
};

#include <poppack.h>

typedef struct _WINUHID_MOUSE_DEVICE {
	PWINUHID_DEVICE Device;
	UCHAR Buttons;
	UCHAR ResolutionMultiplier;
	UCHAR AccumulatedVScroll;
	UCHAR AccumulatedHScroll;
} WINUHID_MOUSE_DEVICE, *PWINUHID_MOUSE_DEVICE;

#define GetVRes(x) ((x) & 0x3)
#define GetHRes(x) (((x) >> 2) & 0x3)

VOID WinUHidMouseCallback(PVOID CallbackContext, PWINUHID_DEVICE Device, PCWINUHID_EVENT Event)
{
	auto mouse = (PWINUHID_MOUSE_DEVICE)CallbackContext;

	//
	// Feature report 18 indicates the resolution of scroll reports
	//

	if (WINUHID_EVENT_TYPE_IS_READ(Event->Type)) {
		if (Event->ReportId != 18) {
			WinUHidCompleteReadEvent(Device, Event, NULL, 0);
			return;
		}

		UCHAR featureReport[2];
		featureReport[0] = Event->ReportId;
		featureReport[1] = mouse->ResolutionMultiplier;
		WinUHidCompleteReadEvent(Device, Event, featureReport, sizeof(featureReport));
	}
	else {
		if (Event->ReportId != 18 || Event->Write.DataLength < 2) {
			WinUHidCompleteWriteEvent(Device, Event, FALSE);
			return;
		}

		mouse->ResolutionMultiplier = Event->Write.Data[1];
		WinUHidCompleteWriteEvent(Device, Event, TRUE);
	}
}

WINUHID_API PWINUHID_MOUSE_DEVICE WinUHidMouseCreate(PCWINUHID_PRESET_DEVICE_INFO Info)
{
	WINUHID_DEVICE_CONFIG config = k_MouseConfig;
	PopulateDeviceInfo(&config, Info);

	if (config.VendorID == 0) {
		SetLastError(ERROR_INVALID_PARAMETER);
		return NULL;
	}

	PWINUHID_MOUSE_DEVICE mouse = (PWINUHID_MOUSE_DEVICE)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*mouse));
	if (!mouse) {
		SetLastError(ERROR_OUTOFMEMORY);
		return NULL;
	}

	mouse->Device = WinUHidCreateDevice(&config);
	if (!mouse->Device) {
		WinUHidMouseDestroy(mouse);
		return NULL;
	}

	if (!WinUHidStartDevice(mouse->Device, WinUHidMouseCallback, mouse)) {
		WinUHidMouseDestroy(mouse);
		return NULL;
	}

	//
	// Send an initial empty input report
	//
	BASIC_REPORT report = {};
	report.Id = BASIC_REPORT_ID;
	if (!WinUHidSubmitInputReport(mouse->Device, &report, sizeof(report))) {
		WinUHidMouseDestroy(mouse);
		return NULL;
	}

	return mouse;
}

WINUHID_API BOOL WinUHidMouseReportMotion(PWINUHID_MOUSE_DEVICE Mouse, SHORT DeltaX, SHORT DeltaY)
{
	BASIC_REPORT report = {};

	report.Id = BASIC_REPORT_ID;
	report.Buttons = Mouse->Buttons;
	report.DeltaX = DeltaX;
	report.DeltaY = DeltaY;

	return WinUHidSubmitInputReport(Mouse->Device, &report, sizeof(report));
}

WINUHID_API BOOL WinUHidMouseReportButton(PWINUHID_MOUSE_DEVICE Mouse, UCHAR ButtonIndex, BOOL Down)
{
	BASIC_REPORT report = {};

	if (ButtonIndex < WUHM_BUTTON_LEFT || ButtonIndex > WUHM_BUTTON_X2) {
		SetLastError(ERROR_INVALID_PARAMETER);
		return FALSE;
	}

	//
	// Button indexes are 1-based (WUHM_BUTTON_LEFT is 1), while the button bits in the
	// report are 0-based (bit 0 is the first button).
	//
	UCHAR mask = (UCHAR)(1 << (ButtonIndex - 1));

	if (Down) {
		Mouse->Buttons |= mask;
	}
	else {
		Mouse->Buttons &= ~mask;
	}

	report.Id = BASIC_REPORT_ID;
	report.Buttons = Mouse->Buttons;

	return WinUHidSubmitInputReport(Mouse->Device, &report, sizeof(report));
}

WINUHID_API BOOL WinUHidMouseReportScroll(PWINUHID_MOUSE_DEVICE Mouse, SHORT ScrollValue, BOOL Horizontal)
{
	BASIC_REPORT report = {};

	report.Id = BASIC_REPORT_ID;
	report.Buttons = Mouse->Buttons;

	//
	// When the resolution multiplier is enabled, each count is 1/WHEEL_DELTA of a tick.
	//
	// When the resolution multiplier is disabled, each count is a whole tick. We handle
	// accumulating of whole ticks on behalf of the caller, since they won't have any
	// idea how the OS has configured the resolution multiplier.
	//
	if (Horizontal) {
		if (GetHRes(Mouse->ResolutionMultiplier)) {
			report.HScroll = ScrollValue;
		}
		else {
			report.HScroll = (ScrollValue + Mouse->AccumulatedHScroll) / WHEEL_DELTA;
			Mouse->AccumulatedHScroll = (ScrollValue + Mouse->AccumulatedHScroll) % WHEEL_DELTA;
		}
	}
	else {
		if (GetVRes(Mouse->ResolutionMultiplier)) {
			report.VScroll = ScrollValue;
		}
		else {
			report.VScroll = (ScrollValue + Mouse->AccumulatedVScroll) / WHEEL_DELTA;
			Mouse->AccumulatedVScroll = (ScrollValue + Mouse->AccumulatedVScroll) % WHEEL_DELTA;
		}
	}

	return WinUHidSubmitInputReport(Mouse->Device, &report, sizeof(report));
}

WINUHID_API VOID WinUHidMouseDestroy(PWINUHID_MOUSE_DEVICE Mouse)
{
	if (!Mouse) {
		return;
	}

	if (Mouse->Device) {
		WinUHidDestroyDevice(Mouse->Device);
	}

	HeapFree(GetProcessHeap(), 0, Mouse);
}