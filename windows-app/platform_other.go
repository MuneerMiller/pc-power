//go:build !windows

package main

import (
	"fmt"
	"os"
	"os/exec"
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
