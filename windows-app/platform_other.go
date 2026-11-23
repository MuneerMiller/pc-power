//go:build !windows

package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"strconv"
	"time"
)

const autostartSupported = false

func autostartGet() bool      { return false }
func autostartSet(bool) error { return fmt.Errorf("only available on Windows") }
func openWindow(url string)   { fmt.Println("Open", url) }
func canHibernate() bool      { return os.Getenv("PCPOWER_NO_HIBERNATE") != "1" }
func runTray()                { select {} }

func doPower(action string) error {
	cmds := map[string][]string{
		"shutdown": {"shutdown", "-h", "+1"}, "restart": {"shutdown", "-r", "+1"},
		"sleep": {"systemctl", "suspend"}, "hibernate": {"systemctl", "hibernate"}, "cancel": {"shutdown", "-c"},
	}
	c := cmds[action]
	return exec.Command(c[0], c[1:]...).Run()
}

func wolRead() WolReport {
	if os.Getenv("PCPOWER_FAKE_WIFI") == "1" { // lets the Wi-Fi screens be tested away from Windows
		return WolReport{Supported: true, Connection: "wifi", Adapters: []WolAdapter{{Name: "Intel Wi-Fi 6 AX200", Magic: "Enabled", Pattern: "Disabled", Wifi: true, Active: true}}}
	}
	return WolReport{Supported: false}
}
func wolFix() error { return fmt.Errorf("only available on Windows") }

const wakeSupported = true

var (
	otherWakeTimer *time.Timer
	otherWakeFired = make(chan struct{}, 1)
)

func wakeInit() <-chan struct{} { return otherWakeFired }

func wakeArm(t time.Time) error {
	if otherWakeTimer != nil {
		otherWakeTimer.Stop()
	}
	if !t.IsZero() {
		otherWakeTimer = time.AfterFunc(time.Until(t), func() {
			select {
			case otherWakeFired <- struct{}{}:
			default:
			}
		})
	}
	return nil
}

func wakeKeepOn(time.Duration) {}

// ---- everything below stands in for Windows-only features, so the core can be run and tested anywhere ----

const installSupported = false

func installStart() error { return fmt.Errorf("only available on Windows") }

func platformMain() {
	background := flag.Bool("background", false, "start without opening the window")
	flag.Parse()
	dataDir = userDataDir()
	portableMain(*background)
}

// Tests set these to imitate a PC that is being used.
func envInt(name string, def int) int {
	if v, err := strconv.Atoi(os.Getenv(name)); err == nil {
		return v
	}
	return def
}

func sessionIdleSeconds() int {
	if _, err := os.Stat("/tmp/pcpower-not-busy"); err == nil { // lets a test end the "in use" state
		return 3600
	}
	return envInt("PCPOWER_FAKE_IDLE", 3600)
}
func sessionFullscreen() bool { return os.Getenv("PCPOWER_FAKE_FULLSCREEN") == "1" }
func sessionRun(cmd string)   { log.Printf("session action: %s", cmd) }

func powerRequests() []string {
	if b := os.Getenv("PCPOWER_FAKE_BLOCKER"); b != "" {
		if _, err := os.Stat("/tmp/pcpower-not-busy"); err != nil { // lets a test end the "busy" state
			return []string{b}
		}
	}
	return nil
}

func netBytes() (uint64, bool) { return 0, false }

// ---- network type and firewall: test hooks ----

func networkCategory(int) (string, string) {
	if c := os.Getenv("PCPOWER_FAKE_NETWORK"); c != "" {
		return c, "Test network"
	}
	return "private", "Test network"
}

func firewallState() string { return "unknown" }
func fixFirewall() error    { return nil }

func makeNetworkPrivate(int) error {
	os.Setenv("PCPOWER_FAKE_NETWORK", "private")
	return nil
}
