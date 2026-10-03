//go:build windows

package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/user"
	"strconv"
	"time"

	"github.com/hkloudou/WinUHid/examples/go-nodll/vhid"
)

// Pauses that make generated input look like distinct events to Windows and to programs.
const (
	holdButton = 30 * time.Millisecond // between button down and up
	clickGap   = 80 * time.Millisecond // between the two clicks of a double click
	holdKey    = 15 * time.Millisecond // between key down and up
)

// Limits. Nothing here waits without one, so every request ends with an answer:
//
//	200  done (and, for routes that name a position, the pointer was seen to arrive there)
//	400  the URL makes no sense (not a number, unknown key)
//	403  the input was sent but did not take effect: the pointer is not where it was sent.
//	     The reason is not diagnosed (no screen, the screen belongs to a Remote Desktop
//	     session, the lock screen, ...); nothing further is done for that request.
//	500  the driver reported an error or did not answer in time, the screen could not be
//	     read, or the program was still busy with an earlier request.
const (
	busyLimit    = 3 * time.Second        // how long a request waits for an earlier one to finish
	typeLimit    = 256                    // characters one /type request may carry
	keysLimit    = 8                      // keys one combination may name
	arriveLimit  = 400 * time.Millisecond // how long the pointer is given to arrive
	arriveMargin = 1                      // pixels of tolerance when checking where it arrived
)

// errNoEffect marks failures of the "sent, but nothing happened" kind (answered with 403).
var errNoEffect = errors.New("the input did not take effect")

// server holds the three virtual devices for as long as the program runs.
type server struct {
	keyboard *vhid.Keyboard
	relative *vhid.Mouse         // for /mouse/rel and the wheel
	pointer  *vhid.AbsoluteMouse // for everything that names a screen position
	started  time.Time
	quit     chan struct{}

	// busy holds one token while a request's input is being sent, so that the steps of two
	// requests (move, press, release) cannot interleave.
	busy chan struct{}
}

func newServer() *server {
	return &server{started: time.Now(), quit: make(chan struct{}), busy: make(chan struct{}, 1)}
}

// exclusively runs action while no other request is sending input. It gives up, instead of
// queueing without end, when an earlier request does not finish within busyLimit.
func (s *server) exclusively(action func() error) error {
	select {
	case s.busy <- struct{}{}:
	case <-time.After(busyLimit):
		return fmt.Errorf("still busy with an earlier request after %v", busyLimit)
	}
	defer func() { <-s.busy }()
	return action()
}

func (s *server) routes() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/{$}", s.help)
	mux.HandleFunc("/status", s.status)
	mux.HandleFunc("/quit", s.quitNow)

	mux.HandleFunc("/mouse/move/{x}/{y}", s.at(func() error { return nil }))
	mux.HandleFunc("/mouse/click/{x}/{y}", s.at(func() error { return s.click(vhid.ButtonLeft) }))
	mux.HandleFunc("/mouse/rclick/{x}/{y}", s.at(func() error { return s.click(vhid.ButtonRight) }))
	mux.HandleFunc("/mouse/dblclick/{x}/{y}", s.at(func() error {
		if err := s.click(vhid.ButtonLeft); err != nil {
			return err
		}
		time.Sleep(clickGap)
		return s.click(vhid.ButtonLeft)
	}))
	mux.HandleFunc("/mouse/down/{x}/{y}", s.at(func() error { return s.pointer.Button(vhid.ButtonLeft, true) }))
	mux.HandleFunc("/mouse/up/{x}/{y}", s.at(func() error { return s.pointer.Button(vhid.ButtonLeft, false) }))

	mux.HandleFunc("/mouse/rel/{dx}/{dy}", s.relativeMove)
	mux.HandleFunc("/mouse/scroll/{n}", s.scroll)

	mux.HandleFunc("/key/tap/{key}", s.key("tap"))
	mux.HandleFunc("/key/down/{key}", s.key("down"))
	mux.HandleFunc("/key/up/{key}", s.key("up"))
	mux.HandleFunc("/type/{text...}", s.typeText)
	return mux
}

func reply(w http.ResponseWriter, status int, body map[string]any) {
	body["ok"] = status < 400
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	encoder := json.NewEncoder(w)
	encoder.SetIndent("", "  ")
	encoder.Encode(body)
}

// answer reports how an action went: 200, 403 for "no effect", 500 for everything else.
func answer(w http.ResponseWriter, err error, body map[string]any) {
	switch {
	case err == nil:
		reply(w, http.StatusOK, body)
	case errors.Is(err, errNoEffect):
		body["error"] = err.Error()
		reply(w, http.StatusForbidden, body)
	default:
		body["error"] = err.Error()
		reply(w, http.StatusInternalServerError, body)
	}
}

func badRequest(w http.ResponseWriter, message string) {
	reply(w, http.StatusBadRequest, map[string]any{"error": message})
}

func (s *server) help(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	fmt.Fprint(w, `WinUHid HTTP sample: virtual keyboard and mouse over HTTP.
FOR FEASIBILITY TESTS AND LEARNING ONLY. No authentication, no encryption: do not distribute or deploy it.

  /mouse/move/x/y        put the pointer on pixel (x, y) of the primary screen
  /mouse/click/x/y       go there and click the left button
  /mouse/dblclick/x/y    go there and double-click
  /mouse/rclick/x/y      go there and click the right button
  /mouse/down/x/y        go there and press the left button (start of a drag)
  /mouse/up/x/y          go there and release it (end of a drag)
  /mouse/scroll/n        turn the wheel n notches (positive up, negative down)
  /mouse/rel/dx/dy       move relative to where the pointer is (for games)

  /key/tap/NAME          press and release a key; combinations like ctrl+c work
  /key/down/NAME         press and hold
  /key/up/NAME           release
  /type/TEXT             type text (US keyboard layout)

  /status                who and where this program is, screen size, pointer position
  /quit                  remove the devices and exit

Key names: a-z, 0-9, enter, esc, tab, space, backspace, delete, insert, home, end, pgup, pgdn,
up, down, left, right, f1-f12, ctrl, shift, alt, win (and lctrl, rctrl, ...), or a number like 0x28.

Answers: 200 done; 400 bad URL; 403 sent but the pointer did not arrive (nothing further was
done); 500 the driver failed or timed out, the screen could not be read, or still busy.
`)
}

func (s *server) status(w http.ResponseWriter, r *http.Request) {
	body := map[string]any{
		"pid":                os.Getpid(),
		"session":            ownSessionID(),
		"console_session":    consoleSessionID(),
		"in_console_session": ownSessionID() == consoleSessionID(),
		"devices":            []string{"keyboard", "relative mouse", "absolute mouse"},
		"uptime_seconds":     int(time.Since(s.started).Seconds()),
	}
	if current, err := user.Current(); err == nil {
		body["user"] = current.Username
		body["sid"] = current.Uid // S-1-5-18 is SYSTEM
	}
	if info, err := queryDesktop(0); err != nil {
		body["screen_error"] = err.Error()
	} else {
		body["screen"] = map[string]any{"width": info.Width, "height": info.Height, "how": info.Source}
		if info.HasPointer {
			body["pointer"] = map[string]int{"x": info.X, "y": info.Y}
		}
	}
	reply(w, http.StatusOK, body)
}

func (s *server) quitNow(w http.ResponseWriter, r *http.Request) {
	reply(w, http.StatusOK, map[string]any{"action": "quit"})
	select {
	case <-s.quit:
	default:
		close(s.quit)
	}
}

// at builds a handler for the routes that name a pixel. It places the pointer there, checks
// that it really arrived, and only then runs what the route does at that place.
func (s *server) at(then func() error) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		x, errX := strconv.Atoi(r.PathValue("x"))
		y, errY := strconv.Atoi(r.PathValue("y"))
		if errX != nil || errY != nil {
			badRequest(w, "x and y must be whole numbers of pixels")
			return
		}
		body := map[string]any{"x": x, "y": y}
		err := s.exclusively(func() error {
			// The screen size turns pixels into the device's coordinates. A slightly old
			// answer is fine: resolutions rarely change.
			screen, err := queryDesktop(2 * time.Second)
			if err != nil {
				return err
			}
			if screen.Width <= 0 || screen.Height <= 0 {
				return errors.New("the screen size could not be read")
			}
			body["screen"] = fmt.Sprintf("%dx%d", screen.Width, screen.Height)

			if err := s.pointer.MoveToPixel(x, y, screen.Width, screen.Height); err != nil {
				return err
			}
			if screen.Manual {
				// Started with -screen: nothing is read back, so arrival cannot be checked.
				body["verified"] = false
				body["note"] = "started with -screen: where the pointer ended up was not checked"
				time.Sleep(20 * time.Millisecond)
				return then()
			}
			wantX, wantY := min(max(x, 0), screen.Width-1), min(max(y, 0), screen.Height-1)
			if err := waitForPointer(wantX, wantY, body); err != nil {
				return err
			}
			body["verified"] = true
			return then()
		})
		answer(w, err, body)
	}
}

// waitForPointer checks, for a short while, that the pointer is where it was sent.
func waitForPointer(x, y int, body map[string]any) error {
	deadline := time.Now().Add(arriveLimit)
	for {
		time.Sleep(15 * time.Millisecond)
		seen, err := queryDesktop(0)
		if err != nil {
			return err
		}
		if seen.HasPointer {
			body["pointer"] = map[string]int{"x": seen.X, "y": seen.Y}
			dx, dy := seen.X-x, seen.Y-y
			if dx >= -arriveMargin && dx <= arriveMargin && dy >= -arriveMargin && dy <= arriveMargin {
				return nil
			}
		}
		if time.Now().After(deadline) {
			if !seen.HasPointer {
				return fmt.Errorf("%w: the pointer cannot be read on the screen's session", errNoEffect)
			}
			return fmt.Errorf("%w: the pointer is at (%d,%d), not at (%d,%d)", errNoEffect, seen.X, seen.Y, x, y)
		}
	}
}

// click presses and releases a button where the pointer was last placed.
func (s *server) click(button vhid.MouseButton) error {
	if err := s.pointer.Button(button, true); err != nil {
		return err
	}
	time.Sleep(holdButton)
	return s.pointer.Button(button, false)
}

func (s *server) relativeMove(w http.ResponseWriter, r *http.Request) {
	dx, errX := strconv.ParseInt(r.PathValue("dx"), 10, 16)
	dy, errY := strconv.ParseInt(r.PathValue("dy"), 10, 16)
	if errX != nil || errY != nil {
		badRequest(w, "dx and dy must be whole numbers between -32767 and 32767")
		return
	}
	// No arrival check here: how far the pointer goes depends on the user's pointer settings,
	// and programs that take relative input often keep the pointer in place.
	err := s.exclusively(func() error { return s.relative.Move(int16(dx), int16(dy)) })
	answer(w, err, map[string]any{"dx": dx, "dy": dy})
}

func (s *server) scroll(w http.ResponseWriter, r *http.Request) {
	notches, err := strconv.ParseInt(r.PathValue("n"), 10, 8)
	if err != nil {
		badRequest(w, "n must be a whole number between -127 and 127")
		return
	}
	// The relative mouse turns the wheel: its reports carry no position, so the pointer stays put.
	err = s.exclusively(func() error { return s.relative.Scroll(int8(notches)) })
	answer(w, err, map[string]any{"notches": notches})
}

func (s *server) key(action string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		keys, err := parseKeys(r.PathValue("key"))
		if err != nil {
			badRequest(w, err.Error())
			return
		}
		if len(keys) > keysLimit {
			badRequest(w, fmt.Sprintf("at most %d keys in one combination", keysLimit))
			return
		}
		err = s.exclusively(func() error {
			if action != "up" { // "down" and "tap" press, in the order given
				for _, key := range keys {
					if err := s.keyboard.KeyDown(key); err != nil {
						s.keyboard.ReleaseAll()
						return err
					}
					time.Sleep(holdKey)
				}
			}
			if action != "down" { // "up" and "tap" release, last pressed first
				for i := len(keys) - 1; i >= 0; i-- {
					if err := s.keyboard.KeyUp(keys[i]); err != nil {
						return err
					}
					time.Sleep(holdKey)
				}
			}
			return nil
		})
		answer(w, err, map[string]any{"action": action, "keys": r.PathValue("key")})
	}
}

func (s *server) typeText(w http.ResponseWriter, r *http.Request) {
	text := r.PathValue("text")
	if len([]rune(text)) > typeLimit {
		badRequest(w, fmt.Sprintf("at most %d characters per request", typeLimit))
		return
	}
	typed, skipped := 0, 0
	err := s.exclusively(func() error {
		for _, character := range text {
			if r.Context().Err() != nil { // the caller has gone away: stop typing
				s.keyboard.ReleaseAll()
				return errors.New("the request was abandoned by the caller")
			}
			key, shift, ok := vhid.KeyForRune(character)
			if !ok {
				skipped++
				continue
			}
			steps := []struct {
				key  vhid.Key
				down bool
			}{{vhid.KeyLeftShift, true}, {key, true}, {key, false}, {vhid.KeyLeftShift, false}}
			for _, step := range steps {
				if step.key == vhid.KeyLeftShift && !shift {
					continue
				}
				var err error
				if step.down {
					err = s.keyboard.KeyDown(step.key)
				} else {
					err = s.keyboard.KeyUp(step.key)
				}
				if err != nil {
					s.keyboard.ReleaseAll()
					return err
				}
				time.Sleep(holdKey)
			}
			typed++
		}
		return nil
	})
	answer(w, err, map[string]any{"typed": typed, "skipped_not_on_us_keyboard": skipped})
}
