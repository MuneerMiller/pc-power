package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// appVersion is the version shown in Installed apps and in problem reports.
const appVersion = "2.7.0"

// problemReport describes this PC's setup for whoever helps the user. It holds no access keys, pairing
// codes, phone names or public addresses: only what is needed to see why something does not work.
// It is only ever sent if the user chooses to send it, from their own email app.
func problemReport() string {
	var b strings.Builder
	line := func(f string, a ...any) { fmt.Fprintf(&b, f+"\n", a...) }
	mode := "portable copy"
	if serviceMode {
		mode = "installed (Windows service)"
	}
	line("PC Power problem report")
	line("Created: %s", time.Now().Format("2006-01-02 15:04 MST"))
	line("App version: %s (%s)", appVersion, mode)
	line("Windows: %s", osVersion())

	ip, _, bc := netInfo()
	n := netCheck(true)
	line("")
	line("Network: address %s, broadcast %s, network type %q, firewall %s, problem %q", ip, bc, n.Category, n.Firewall, n.Problem)

	w := wolCheck(true)
	wj, _ := json.Marshal(w)
	line("Wake settings: %s", wj)
	line("Can hibernate: %v", canHibernate())

	mu.Lock()
	phones, schedules, paused, idle := len(cfg.Devices), len(cfg.Schedules), cfg.Paused, cfg.Idle
	var events []Event
	if len(cfg.Events) > 15 {
		events = append(events, cfg.Events[len(cfg.Events)-15:]...)
	} else {
		events = append(events, cfg.Events...)
	}
	mu.Unlock()
	line("Paired phones: %d. Schedules: %d (paused: %v). Idle rule: %+v", phones, schedules, paused, idle)
	ti, _ := json.Marshal(wakeInfo())
	line("Turn-on schedules: %s", ti)

	line("")
	line("Recent activity:")
	for _, e := range events {
		line("  %s  %s", e.T, e.Text)
	}

	line("")
	line("Recent log:")
	if data, err := os.ReadFile(filepath.Join(dataDir, "pcpower.log")); err == nil {
		lines := strings.Split(strings.TrimSpace(string(data)), "\n")
		if len(lines) > 60 {
			lines = lines[len(lines)-60:]
		}
		for _, l := range lines {
			line("  %s", l)
		}
	} else {
		line("  (no log)")
	}
	return b.String()
}

func hReport(w http.ResponseWriter, r *http.Request) {
	reply(w, 200, map[string]any{"report": problemReport(), "email": "muneermilleror@gmail.com"})
}
