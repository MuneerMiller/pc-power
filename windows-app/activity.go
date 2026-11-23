package main

// What the PC is doing right now, and everything built on that: postponing a scheduled shutdown while
// the PC is in use, the idle rule, the one-off timer, days off, the activity log, and actions that have
// to run in the signed-in user's session (lock, screen off, mute).

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"
)

type IdleRule struct {
	Enabled bool   `json:"enabled"`
	Minutes int    `json:"minutes"`
	Action  string `json:"action"`
}

type TimerT struct {
	Action string `json:"action"`
	At     string `json:"at"` // RFC 3339
}

type Event struct {
	T    string `json:"t"`
	Kind string `json:"kind"`
	Text string `json:"text"`
}

const (
	maxEvents       = 100
	usedRecently    = 5 * 60           // seconds: someone touched the PC this recently = in use
	downloadKBps    = 500              // sustained transfer above this = a download or upload is running
	waitGiveUp      = 3 * time.Hour    // a postponed schedule is dropped after this long
	helperFreshness = 12 * time.Second // the tray helper reports every 3 s; older than this = nobody signed in
)

var sessionActions = map[string]string{"lock": "Lock", "displayoff": "Screen off", "mute": "Mute or unmute", "signout": "Sign out"}

// act is filled in by the tray helper (which runs in the user's session) and by background samplers.
var act struct {
	sync.Mutex
	idle       int // seconds since keyboard or mouse input, as last reported
	fullscreen bool
	seen       time.Time // when the helper last reported
	started    time.Time
	cmds       []string // session actions waiting for the helper to collect
	blockers   []string
	blockersAt time.Time
	netKBps    int
}

type waitingT struct {
	Action string
	Since  time.Time
	Reason string
}

var (
	waiting   *waitingT // a scheduled action postponed because the PC is in use; guarded by mu
	idleFired bool      // the idle rule already acted on this stretch of idleness
)

func init() { act.started = time.Now() }

// addEventLocked must be called with mu held.
func addEventLocked(kind, text string) {
	cfg.Events = append(cfg.Events, Event{time.Now().Format(time.RFC3339), kind, text})
	if len(cfg.Events) > maxEvents {
		cfg.Events = cfg.Events[len(cfg.Events)-maxEvents:]
	}
	saveConfig()
	log.Printf("event [%s] %s", kind, text)
}

func addEvent(kind, text string) {
	mu.Lock()
	addEventLocked(kind, text)
	mu.Unlock()
}

// signedIn reports whether a user session is running the tray helper right now.
func signedIn() bool {
	act.Lock()
	defer act.Unlock()
	return time.Since(act.seen) < helperFreshness
}

// idleSeconds is how long since anyone used the PC. With nobody signed in, it counts from the last
// time someone was, or from when PC Power started.
func idleSeconds() int {
	act.Lock()
	defer act.Unlock()
	if time.Since(act.seen) < helperFreshness {
		return act.idle
	}
	since := act.started
	if !act.seen.IsZero() {
		since = act.seen.Add(-time.Duration(act.idle) * time.Second)
	}
	return int(time.Since(since).Seconds())
}

func blockers() []string {
	act.Lock()
	fresh := time.Since(act.blockersAt) < 20*time.Second
	b := act.blockers
	act.Unlock()
	if fresh {
		return b
	}
	b = powerRequests()
	act.Lock()
	act.blockers, act.blockersAt = b, time.Now()
	act.Unlock()
	return b
}

// busyReasons says, in plain words, why turning the PC off now might interrupt something.
// withIdle=false leaves out "someone used it recently" (the idle rule does its own idle check).
func busyReasons(withIdle bool) []string {
	var out []string
	if withIdle && signedIn() {
		if s := idleSeconds(); s < usedRecently {
			if s < 60 {
				out = append(out, "Someone is using the PC right now")
			} else {
				out = append(out, fmt.Sprintf("Someone used the PC %d minutes ago", s/60))
			}
		}
	}
	act.Lock()
	fs, kb := act.fullscreen && time.Since(act.seen) < helperFreshness, act.netKBps
	act.Unlock()
	if fs {
		out = append(out, "A full-screen app is open (a game, video or presentation)")
	}
	for _, b := range blockers() {
		out = append(out, b+" is keeping the PC awake")
	}
	if kb >= downloadKBps {
		out = append(out, fmt.Sprintf("A download or upload is running (%.1f MB/s)", float64(kb)/1024))
	}
	return out
}

func netSampler() {
	last, ok := netBytes()
	for {
		time.Sleep(5 * time.Second)
		now, ok2 := netBytes()
		if ok && ok2 && now >= last {
			kb := int((now - last) / 1024 / 5)
			act.Lock()
			act.netKBps = (act.netKBps + kb) / 2 // smooth out short bursts
			act.Unlock()
		}
		last, ok = now, ok2
	}
}

// sessionDo queues an action for the tray helper, which is the only part running in the user's session.
func sessionDo(action string) error {
	if !signedIn() {
		return errors.New("Nobody is signed in on the PC, so that cannot be done right now.")
	}
	act.Lock()
	act.cmds = append(act.cmds, action)
	act.Unlock()
	return nil
}

// ---- scheduling extras, called from the scheduler tick ----

func onSkipDate(date string) bool {
	for _, d := range cfg.SkipDates {
		if d == date {
			return true
		}
	}
	return false
}

// runScheduled performs a scheduled power action, or postpones it while the PC is in use.
func runScheduled(action string, force bool) {
	if !force {
		if r := busyReasons(true); len(r) > 0 {
			mu.Lock()
			waiting = &waitingT{action, time.Now(), r[0]}
			addEventLocked("schedule", fmt.Sprintf("Scheduled %s postponed: %s. It will happen once the PC is free.", strings.ToLower(labels[action]), lowerFirst(r[0])))
			mu.Unlock()
			return
		}
	}
	addEvent("schedule", "Scheduled "+strings.ToLower(labels[action]))
	requestPower(action, false)
}

func lowerFirst(s string) string {
	if s == "" {
		return s
	}
	return strings.ToLower(s[:1]) + s[1:]
}

func checkWaiting() {
	mu.Lock()
	w := waiting
	mu.Unlock()
	if w == nil {
		return
	}
	if time.Since(w.Since) > waitGiveUp {
		mu.Lock()
		waiting = nil
		addEventLocked("schedule", fmt.Sprintf("Scheduled %s skipped: the PC stayed in use for %d hours.", strings.ToLower(labels[w.Action]), int(waitGiveUp.Hours())))
		mu.Unlock()
		return
	}
	if len(busyReasons(true)) == 0 {
		mu.Lock()
		waiting = nil
		mu.Unlock()
		addEvent("schedule", "The PC is free now: "+strings.ToLower(labels[w.Action])+" (postponed earlier)")
		requestPower(w.Action, false)
	}
}

func checkTimer(now time.Time) {
	mu.Lock()
	t := cfg.Timer
	due := false
	if t != nil {
		at, err := time.Parse(time.RFC3339, t.At)
		due = err != nil || !now.Before(at)
		if due {
			cfg.Timer = nil
			addEventLocked("timer", "Timer: "+strings.ToLower(labels[t.Action]))
		}
	}
	mu.Unlock()
	if due && actions[t.Action] {
		requestPower(t.Action, true) // the user asked for this exact moment, so it is not postponed
	}
}

func checkIdle() {
	mu.Lock()
	r := cfg.Idle
	mu.Unlock()
	if !r.Enabled || r.Minutes < 1 || !actions[r.Action] {
		idleFired = false
		return
	}
	if idleSeconds() < r.Minutes*60 {
		idleFired = false
		return
	}
	mu.Lock()
	counting := pendingNow() != nil || waiting != nil
	mu.Unlock()
	if idleFired || counting || len(busyReasons(false)) > 0 {
		return
	}
	idleFired = true
	addEvent("idle", fmt.Sprintf("%s: nobody used the PC for %d minutes", labels[r.Action], r.Minutes))
	requestPower(r.Action, false)
}

// ---- wake signal ----

func sendMagic(mac net.HardwareAddr, hosts []string) int {
	pkt := make([]byte, 0, 102)
	for i := 0; i < 6; i++ {
		pkt = append(pkt, 0xff)
	}
	for i := 0; i < 16; i++ {
		pkt = append(pkt, mac...)
	}
	sent := 0
	conn, err := net.ListenUDP("udp4", nil)
	if err != nil {
		return 0
	}
	defer conn.Close()
	for _, h := range hosts {
		for _, port := range []int{9, 7} {
			if addr, err := net.ResolveUDPAddr("udp4", fmt.Sprintf("%s:%d", h, port)); err == nil {
				for i := 0; i < 3; i++ {
					if _, err := conn.WriteToUDP(pkt, addr); err == nil {
						sent++
					}
				}
			}
		}
	}
	return sent
}

// ---- handlers ----

func activityView() map[string]any {
	reasons := busyReasons(true)
	if reasons == nil {
		reasons = []string{}
	}
	return map[string]any{"busy": reasons, "idleSeconds": idleSeconds(), "signedIn": signedIn()}
}

// hTimer sets or clears the one-off "turn off in N minutes" timer.
func hTimer(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	defer mu.Unlock()
	if r.Method == "DELETE" {
		cfg.Timer = nil
		saveConfig()
		reply(w, 200, map[string]any{"ok": true, "message": "Timer cancelled."})
		return
	}
	var b struct {
		Action  string
		Minutes int
	}
	json.NewDecoder(r.Body).Decode(&b)
	if !actions[b.Action] || b.Minutes < 1 || b.Minutes > 24*60 {
		fail(w, 400, "Choose an action and between 1 minute and 24 hours.")
		return
	}
	cfg.Timer = &TimerT{b.Action, time.Now().Add(time.Duration(b.Minutes) * time.Minute).Format(time.RFC3339)}
	saveConfig()
	unit := "minutes"
	if b.Minutes == 1 {
		unit = "minute"
	}
	reply(w, 200, map[string]any{"ok": true, "message": fmt.Sprintf("%s in %d %s.", labels[b.Action], b.Minutes, unit)})
}

// hAutomation saves the idle rule and the days off.
func hAutomation(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Idle      *IdleRule
		SkipDates *[]string
		Paused    *bool
	}
	json.NewDecoder(r.Body).Decode(&b)
	mu.Lock()
	defer mu.Unlock()
	if b.Idle != nil {
		if b.Idle.Enabled && (!actions[b.Idle.Action] || b.Idle.Minutes < 5 || b.Idle.Minutes > 24*60) {
			fail(w, 400, "Choose an action and at least 5 minutes.")
			return
		}
		cfg.Idle = *b.Idle
	}
	if b.SkipDates != nil {
		seen, out := map[string]bool{}, []string{}
		today := time.Now().Format("2006-01-02")
		for _, d := range *b.SkipDates {
			if _, err := time.Parse("2006-01-02", d); err == nil && dateRe.MatchString(d) && !seen[d] && d >= today {
				seen[d] = true
				out = append(out, d)
			}
		}
		if len(out) > 60 {
			fail(w, 400, "Too many days off.")
			return
		}
		sort.Strings(out)
		cfg.SkipDates = out
	}
	if b.Paused != nil && *b.Paused != cfg.Paused {
		cfg.Paused = *b.Paused
		if cfg.Paused {
			waiting = nil
			addEventLocked("schedule", "Schedules paused, by "+who(r))
		} else {
			addEventLocked("schedule", "Schedules resumed, by "+who(r))
		}
		kickWake()
	}
	saveConfig()
	reply(w, 200, map[string]bool{"ok": true})
}

// hWakePeer makes this PC send the wake signal for another PC on its own network, so a phone that
// cannot reach that network directly can still turn the other PC on.
func hWakePeer(w http.ResponseWriter, r *http.Request) {
	var b struct{ Mac, Name string }
	json.NewDecoder(r.Body).Decode(&b)
	mac, err := net.ParseMAC(strings.TrimSpace(b.Mac))
	if err != nil || len(mac) != 6 {
		fail(w, 400, "That is not a valid hardware (MAC) address.")
		return
	}
	_, _, bc := netInfo()
	hosts := []string{"255.255.255.255"}
	if bc != "" {
		hosts = append(hosts, bc)
	}
	if sendMagic(mac, hosts) == 0 {
		fail(w, 500, "This PC could not send the wake signal.")
		return
	}
	name := strings.TrimSpace(b.Name)
	if name == "" || len(name) > 60 {
		name = mac.String()
	}
	addEvent("wake", "Sent the wake signal for "+name)
	reply(w, 200, map[string]any{"ok": true})
}

// hPresence is called by the tray helper every few seconds: it reports what the user's session is
// doing and collects any actions that have to run there.
func hPresence(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Idle       int
		Fullscreen bool
	}
	json.NewDecoder(r.Body).Decode(&b)
	act.Lock()
	act.idle, act.fullscreen, act.seen = b.Idle, b.Fullscreen, time.Now()
	cmds := act.cmds
	act.cmds = nil
	act.Unlock()
	if cmds == nil {
		cmds = []string{}
	}
	reply(w, 200, map[string]any{"commands": cmds})
}
