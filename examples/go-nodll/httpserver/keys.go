//go:build windows

package main

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/hkloudou/WinUHid/examples/go-nodll/vhid"
)

// keyNames maps the names accepted in URLs to keys. Single letters and digits are handled
// separately, and any key can also be given by number, for example 0x28.
var keyNames = map[string]vhid.Key{
	"enter": 0x28, "esc": 0x29, "escape": 0x29, "backspace": 0x2A, "tab": 0x2B, "space": 0x2C,
	"minus": 0x2D, "equal": 0x2E, "capslock": 0x39,
	"f1": 0x3A, "f2": 0x3B, "f3": 0x3C, "f4": 0x3D, "f5": 0x3E, "f6": 0x3F,
	"f7": 0x40, "f8": 0x41, "f9": 0x42, "f10": 0x43, "f11": 0x44, "f12": 0x45,
	"printscreen": 0x46, "scrolllock": 0x47, "pause": 0x48,
	"insert": 0x49, "home": 0x4A, "pageup": 0x4B, "pgup": 0x4B,
	"delete": 0x4C, "del": 0x4C, "end": 0x4D, "pagedown": 0x4E, "pgdn": 0x4E,
	"right": 0x4F, "left": 0x50, "down": 0x51, "up": 0x52,
	"numlock": 0x53, "menu": 0x65,

	"ctrl": vhid.KeyLeftControl, "lctrl": vhid.KeyLeftControl, "rctrl": vhid.KeyRightControl,
	"shift": vhid.KeyLeftShift, "lshift": vhid.KeyLeftShift, "rshift": vhid.KeyRightShift,
	"alt": vhid.KeyLeftAlt, "lalt": vhid.KeyLeftAlt, "ralt": vhid.KeyRightAlt,
	"win": vhid.KeyLeftGUI, "lwin": vhid.KeyLeftGUI, "rwin": vhid.KeyRightGUI,
}

// parseKey turns one key name into a key.
func parseKey(name string) (vhid.Key, error) {
	name = strings.ToLower(strings.TrimSpace(name))
	if key, ok := keyNames[name]; ok {
		return key, nil
	}
	if len(name) == 1 {
		switch c := name[0]; {
		case c >= 'a' && c <= 'z':
			return vhid.KeyA + vhid.Key(c-'a'), nil
		case c >= '1' && c <= '9':
			return vhid.Key1 + vhid.Key(c-'1'), nil
		case c == '0':
			return vhid.Key0, nil
		}
	}
	if strings.HasPrefix(name, "0x") {
		if number, err := strconv.ParseUint(name[2:], 16, 8); err == nil && number != 0 {
			return vhid.Key(number), nil
		}
	}
	return 0, fmt.Errorf("unknown key %q", name)
}

// parseKeys turns "ctrl+shift+esc" into its keys, in the order they are to be pressed.
func parseKeys(combination string) ([]vhid.Key, error) {
	var keys []vhid.Key
	for _, name := range strings.Split(combination, "+") {
		key, err := parseKey(name)
		if err != nil {
			return nil, err
		}
		keys = append(keys, key)
	}
	return keys, nil
}
