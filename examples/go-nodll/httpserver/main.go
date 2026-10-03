//go:build windows

// Command winuhid-http is a reference HTTP front end for a virtual keyboard and mouse.
//
// On start it creates the virtual devices; while it runs, simple URLs such as
// /mouse/click/800/450 drive them; on exit it removes them again. The devices live inside
// this process, so they also disappear if the process is killed.
//
// Only one copy should own the devices. A copy that finds another one already listening on
// its address tells that one to quit, waits for it to let go, and then takes over.
//
// It works when started from an elevated prompt in the user's session, and when started as
// SYSTEM outside it (a service or a scheduled task).
//
// This program exists for feasibility tests and for learning. It must not be distributed to
// users or deployed as it is: it has no authentication, no encryption, no consent of or notice
// to the person at the machine, and no audit trail. Anyone who can reach the address can type
// and click on this machine. See README.md for the boundaries and the compliance risks.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/hkloudou/WinUHid/examples/go-nodll/vhid"
)

// Placeholder identifiers for testing. A product must use identifiers of its own.
const (
	testVendorID          = 0x1234
	testKeyboardProductID = 0x56A1
	testMouseProductID    = 0x56A2
	testAbsoluteProductID = 0x56A3
)

func main() {
	address := flag.String("addr", "127.0.0.1:8765", "address to listen on")
	logFile := flag.String("log", "", "also write the log to this file (useful when there is no console window)")
	screen := flag.String("screen", "", "screen size as WIDTHxHEIGHT, e.g. 1920x1080: use this instead of reading the screen; pointer arrival is then not checked")
	desktopInfoOut := flag.String("desktop-info", "", "internal: write screen size and pointer position to this file and exit")
	flag.Parse()

	// The short-lived copy that reads the screen from inside the user's session.
	if *desktopInfoOut != "" {
		if err := writeDesktopInfo(*desktopInfoOut); err != nil {
			os.Exit(1)
		}
		return
	}

	if *logFile != "" {
		file, err := os.OpenFile(*logFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
		if err != nil {
			log.Fatalf("cannot open log file: %v", err)
		}
		defer file.Close()
		log.SetOutput(io.MultiWriter(os.Stderr, file))
	}

	if *screen != "" {
		var width, height int
		if _, err := fmt.Sscanf(*screen, "%dx%d", &width, &height); err != nil || width <= 0 || height <= 0 {
			log.Fatalf("-screen must look like 1920x1080")
		}
		manualScreen = &desktopInfo{Width: width, Height: height, Manual: true, Source: "given with -screen; nothing is read or checked"}
		log.Printf("screen size given as %dx%d: the screen is not read and pointer arrival is not checked", width, height)
	}

	if err := run(*address); err != nil {
		log.Printf("stopped with an error: %v", err)
		os.Exit(1)
	}
	log.Printf("stopped")
}

func run(address string) error {
	// 1. Make sure no earlier copy still owns devices: if one is listening, ask it to quit.
	listener, err := listenTakingOver(address)
	if err != nil {
		return err
	}
	defer listener.Close()

	// 2. Create the devices.
	s := newServer()
	if s.keyboard, err = vhid.NewKeyboard(testVendorID, testKeyboardProductID); err != nil {
		return explain(err)
	}
	defer s.keyboard.Close()
	if s.relative, err = vhid.NewMouse(testVendorID, testMouseProductID); err != nil {
		return explain(err)
	}
	defer s.relative.Close()
	if s.pointer, err = vhid.NewAbsoluteMouse(testVendorID, testAbsoluteProductID); err != nil {
		return explain(err)
	}
	defer s.pointer.Close()
	log.Printf("virtual keyboard, relative mouse and absolute mouse created (pid %d, session %d, console session %d)",
		os.Getpid(), ownSessionID(), consoleSessionID())

	// Windows needs a moment to set up new devices; input sent before that has no effect.
	time.Sleep(1500 * time.Millisecond)

	// 3. Serve until asked to stop: /quit, Ctrl+C, the console window closing, or a service stop.
	httpServer := &http.Server{
		Handler:           s.routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      60 * time.Second, // above the longest request: a full-length /type
		IdleTimeout:       60 * time.Second,
	}
	serveError := make(chan error, 1)
	go func() { serveError <- httpServer.Serve(listener) }()
	log.Printf("listening on http://%s/", listener.Addr())
	log.Printf("FOR FEASIBILITY TESTS AND LEARNING ONLY: no authentication, no encryption. Do not distribute or deploy it.")

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	select {
	case <-s.quit:
		log.Printf("asked to quit over HTTP")
	case received := <-signals:
		log.Printf("received %v", received)
	case err := <-serveError:
		return err
	}

	// 4. Remove the devices first and only then give up the address, so that a copy waiting
	//    to take over never starts while the old devices still exist.
	log.Printf("removing the virtual devices")
	removed := make(chan struct{})
	go func() {
		s.pointer.Close()
		s.relative.Close()
		s.keyboard.Close()
		close(removed)
	}()
	select {
	case <-removed:
	case <-time.After(5 * time.Second):
		// Do not hang on exit either: when the process ends, Windows takes the devices away itself.
		log.Printf("removing the devices is taking too long; exiting and leaving it to Windows")
		os.Exit(1)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	httpServer.Shutdown(ctx)
	return nil
}

// explain turns the two common start-up problems into plain advice.
func explain(err error) error {
	switch {
	case errors.Is(err, vhid.ErrDriverNotInstalled):
		return errors.New("the WinUHid driver is not installed on this machine; run install.cmd first")
	case errors.Is(err, vhid.ErrAccessDenied):
		return errors.New("access denied: start this from an elevated prompt, or as SYSTEM")
	}
	return err
}

// listenTakingOver listens on the address. If another copy of this program already does, it
// is asked to quit and the address is claimed once it has let go.
func listenTakingOver(address string) (net.Listener, error) {
	listener, firstErr := net.Listen("tcp", address)
	if firstErr == nil {
		return listener, nil
	}

	_, port, err := net.SplitHostPort(address)
	if err != nil {
		return nil, firstErr
	}
	client := &http.Client{Timeout: 3 * time.Second}
	response, err := client.Get("http://" + net.JoinHostPort("127.0.0.1", port) + "/quit")
	if err != nil {
		return nil, fmt.Errorf("%s is in use and whatever holds it did not answer /quit: %w", address, firstErr)
	}
	response.Body.Close()
	log.Printf("another copy was running; asked it to quit and waiting for it to let go")

	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		time.Sleep(200 * time.Millisecond)
		if listener, err = net.Listen("tcp", address); err == nil {
			// Its devices are removed as it exits; give Windows a moment to finish that
			// before new ones are created.
			time.Sleep(time.Second)
			return listener, nil
		}
	}
	return nil, fmt.Errorf("%s is still in use 10 seconds after asking the other copy to quit", address)
}
