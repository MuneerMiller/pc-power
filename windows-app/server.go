package main

// Everything that listens on the network lives here.
//
// Two separate servers, so a mistake in one cannot expose the other:
//   - phones: HTTPS (TLS 1.3) on all interfaces, every request needs a per-phone token
//   - this PC's own window: plain HTTP bound to 127.0.0.1 only
//
// Pairing: the phone and PC both prove they know the pairing code without sending it, and the proof is
// tied to the PC's TLS certificate. Someone in the middle of the connection has a different certificate,
// so their proofs never match, and what they capture cannot be used to guess the code.

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	pairIterations = 20000
	maxDevices     = 20
)

var (
	certFP   [32]byte // SHA-256 of the TLS certificate; phones pin this
	pairKeyC struct {
		code string
		key  []byte
	}
	lastSeen = map[string]time.Time{} // device id -> last request, guarded by mu
)

// ---- TLS identity ----

func loadOrCreateCert(dir string) (tls.Certificate, error) {
	certFile, keyFile := filepath.Join(dir, "cert.pem"), filepath.Join(dir, "key.pem")
	if c, err := tls.LoadX509KeyPair(certFile, keyFile); err == nil {
		certFP = sha256.Sum256(c.Certificate[0])
		return c, nil
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, err
	}
	serial, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 126))
	tmpl := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: "PC Power"},
		NotBefore:    time.Now().Add(-24 * time.Hour),
		NotAfter:     time.Now().AddDate(30, 0, 0),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:     []string{"pcpower.local"},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, err
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return tls.Certificate{}, err
	}
	os.MkdirAll(dir, 0o700)
	if err := os.WriteFile(certFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o600); err != nil {
		return tls.Certificate{}, err
	}
	if err := os.WriteFile(keyFile, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER}), 0o600); err != nil {
		return tls.Certificate{}, err
	}
	certFP = sha256.Sum256(der)
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, nil
}

// pairKey stretches the pairing code, salted with this PC's certificate. Must be called with mu held.
func pairKey() []byte {
	if pairKeyC.code != cfg.Token {
		k, _ := pbkdf2.Key(sha256.New, cfg.Token, certFP[:], pairIterations, 32)
		pairKeyC.code, pairKeyC.key = cfg.Token, k
	}
	return pairKeyC.key
}

func mac256(key []byte, parts ...[]byte) []byte {
	h := hmac.New(sha256.New, key)
	for _, p := range parts {
		h.Write(p)
	}
	return h.Sum(nil)
}

func tokenHash(token string) string {
	s := sha256.Sum256([]byte(token))
	return hex.EncodeToString(s[:])
}

func prettyCode(c string) string {
	if len(c) != 12 {
		return c
	}
	return c[:4] + "-" + c[4:8] + "-" + c[8:]
}

// ---- who is asking ----

func remoteIP(r *http.Request) net.IP {
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	return net.ParseIP(host)
}

var cgnat = &net.IPNet{IP: net.IPv4(100, 64, 0, 0), Mask: net.CIDRMask(10, 32)} // carrier NAT and VPNs such as Tailscale

var testAllPublic = os.Getenv("PCPOWER_TEST_ALL_PUBLIC") == "1" // tests only: can only ever reduce access

func onLocalNetwork(ip net.IP) bool {
	return !testAllPublic && ip != nil && (ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() || cgnat.Contains(ip))
}

// Failed attempts are counted per address; after too many, that address is locked out for a while.
var (
	failMu sync.Mutex
	fails  = map[string]*failRec{}
)

type failRec struct {
	n     int
	until time.Time
}

const (
	failLimit  = 8
	failWindow = 10 * time.Minute
)

func lockedOut(ip string) bool {
	failMu.Lock()
	defer failMu.Unlock()
	f := fails[ip]
	if f != nil && time.Now().After(f.until) {
		delete(fails, ip)
		f = nil
	}
	return f != nil && f.n >= failLimit
}

func recordFail(ip string) {
	failMu.Lock()
	defer failMu.Unlock()
	if len(fails) > 5000 { // never let a flood grow this without bound
		fails = map[string]*failRec{}
	}
	f := fails[ip]
	if f == nil {
		f = &failRec{}
		fails[ip] = f
	}
	f.n++
	f.until = time.Now().Add(failWindow)
}

func reply(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func fail(w http.ResponseWriter, code int, msg string) {
	reply(w, code, map[string]string{"error": msg})
}

// gate runs before anything else for requests from the network.
// homeOnly is for anything an unpaired device may call (saying hello, pairing): those are never
// answered from outside the local network, whatever the settings, so the internet cannot even try a code.
func gate(w http.ResponseWriter, r *http.Request, homeOnly bool) (ip string, ok bool) {
	r.Body = http.MaxBytesReader(w, r.Body, 1<<14)
	addr := remoteIP(r)
	mu.Lock()
	lanOnly := *cfg.LanOnly
	mu.Unlock()
	if !onLocalNetwork(addr) {
		if homeOnly {
			http.NotFound(w, r) // look like nothing is here
			return "", false
		}
		if lanOnly {
			fail(w, http.StatusForbidden, "This PC only accepts phones on its own network.")
			return "", false
		}
	}
	ip = addr.String()
	if lockedOut(ip) {
		fail(w, http.StatusTooManyRequests, "Too many failed attempts. Wait ten minutes.")
		return "", false
	}
	return ip, true
}

// phone wraps a handler so it only runs for a paired phone presenting its token.
func phone(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if _, ok := gate(w, r, false); !ok {
			return
		}
		tok := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		got := []byte(tokenHash(tok))
		id, name := "", ""
		mu.Lock()
		for _, d := range cfg.Devices { // compare against every device so timing reveals nothing
			if subtle.ConstantTimeCompare(got, []byte(d.TokenHash)) == 1 {
				id, name = d.ID, d.Name
			}
		}
		if id != "" {
			lastSeen[id] = time.Now()
		}
		mu.Unlock()
		if id == "" || len(tok) < 20 {
			// Not counted towards the lockout: a 256-bit token cannot be guessed, and a phone that was
			// removed must still be able to pair again straight away. Only wrong pairing codes count.
			time.Sleep(300 * time.Millisecond)
			fail(w, http.StatusUnauthorized, "This phone is not paired with this PC. Pair it again.")
			return
		}
		h(w, r.WithContext(context.WithValue(r.Context(), whoKey{}, name)))
	}
}

type whoKey struct{}

// who names the requester for the activity log: a paired phone's name, or "this PC".
func who(r *http.Request) string {
	if n, ok := r.Context().Value(whoKey{}).(string); ok && n != "" {
		return n
	}
	return "this PC"
}

// local wraps a handler for this PC's own window. The server is bound to 127.0.0.1, and on top of that:
// the Host check stops DNS rebinding, the Origin check and custom header stop other websites.
func local(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, 1<<14)
		host := r.Host
		if hh, _, err := net.SplitHostPort(r.Host); err == nil {
			host = hh
		}
		origin := r.Header.Get("Origin")
		ip := remoteIP(r)
		if ip == nil || !ip.IsLoopback() || (host != "127.0.0.1" && host != "localhost") ||
			r.Header.Get("X-PCPower") != "1" || (origin != "" && origin != "http://"+r.Host) {
			fail(w, http.StatusForbidden, "Not allowed")
			return
		}
		// The key is only readable by the user PC Power was set up for, so other accounts on a shared
		// PC cannot control it through this local port.
		if subtle.ConstantTimeCompare([]byte(r.Header.Get("X-PCPower-Key")), []byte(localKey)) != 1 || localKey == "" {
			fail(w, http.StatusUnauthorized, "Open PC Power from its tray icon or the Start menu.")
			return
		}
		h(w, r)
	}
}

// ---- handlers shared by both servers ----

func status() map[string]any {
	ip, mac, bc := netInfo()
	hib := canHibernate()
	conn := wolCheck(false).Connection
	activity := activityView()
	mu.Lock()
	defer mu.Unlock()
	var timer, wait any
	if cfg.Timer != nil {
		if at, err := time.Parse(time.RFC3339, cfg.Timer.At); err == nil {
			timer = map[string]any{"action": cfg.Timer.Action, "seconds": int(time.Until(at).Seconds()) + 1, "at": at.Format("15:04")}
		}
	}
	if waiting != nil {
		wait = map[string]any{"action": waiting.Action, "reason": waiting.Reason}
	}
	events := cfg.Events
	if len(events) > 30 {
		events = events[len(events)-30:]
	}
	var pend any
	if p := pendingNow(); p != nil {
		pend = map[string]any{"action": p.Action, "seconds": int(time.Until(p.At).Seconds()) + 1}
	}
	return map[string]any{"app": "pcpower", "version": 9, "name": cfg.Name, "ip": ip, "mac": mac, "broadcast": bc, "port": cfg.Port,
		"time": time.Now().Format("15:04"), "schedules": cfg.Schedules, "pending": pend, "canHibernate": hib, "connection": conn, "wakeTest": wakeTestStatus(), "turnOn": wakeInfo(),
		"activity": activity, "timer": timer, "waiting": wait, "idle": cfg.Idle, "skipDates": cfg.SkipDates, "events": events}
}

func hStatus(w http.ResponseWriter, r *http.Request) { reply(w, 200, status()) }

func hPower(w http.ResponseWriter, r *http.Request) {
	var b struct{ Action string }
	json.NewDecoder(r.Body).Decode(&b)
	if label, ok := sessionActions[b.Action]; ok {
		if err := sessionDo(b.Action); err != nil {
			fail(w, http.StatusConflict, err.Error())
			return
		}
		addEvent("power", label+", from "+who(r))
		reply(w, 200, map[string]any{"ok": true, "message": label + " sent."})
		return
	}
	if !actions[b.Action] && b.Action != "cancel" {
		fail(w, 400, "Unknown action")
		return
	}
	mu.Lock()
	hadWaiting := waiting != nil
	waiting = nil // a person has taken over: drop any postponed schedule
	mu.Unlock()
	msg, err := requestPower(b.Action, true)
	if err != nil {
		fail(w, http.StatusConflict, err.Error())
		return
	}
	if b.Action == "cancel" {
		if hadWaiting {
			msg = "Postponed schedule cancelled. " + msg
		}
		addEvent("power", "Cancelled, from "+who(r))
	} else {
		addEvent("power", labels[b.Action]+", from "+who(r))
	}
	reply(w, 200, map[string]any{"ok": true, "message": msg})
}

func hAddSchedule(w http.ResponseWriter, r *http.Request) {
	var s Schedule
	if json.NewDecoder(r.Body).Decode(&s) != nil || (!actions[s.Action] && s.Action != "wake") {
		fail(w, 400, "Unknown action")
		return
	}
	if !timeRe.MatchString(s.Time) {
		fail(w, 400, "Time must be HH:MM")
		return
	}
	days, seen := []int{}, map[int]bool{}
	for _, d := range s.Days {
		if d >= 0 && d <= 6 && !seen[d] {
			seen[d] = true
			days = append(days, d)
		}
	}
	if len(days) == 0 {
		if _, err := time.Parse("2006-01-02", s.Date); err != nil || !dateRe.MatchString(s.Date) {
			fail(w, 400, "Pick days to repeat on, or a date")
			return
		}
	} else {
		s.Date = ""
	}
	if s.WhenBusy != "force" || s.Action == "wake" {
		s.WhenBusy = "wait"
	}
	s.ID, s.Days, s.Enabled, s.LastFired = newID(), days, true, ""
	mu.Lock()
	defer mu.Unlock()
	for _, o := range cfg.Schedules {
		if o.Time == s.Time && sameDay(o, s) {
			fail(w, http.StatusConflict, fmt.Sprintf("There is already a schedule at %s on that day (%s). Delete it first, or pick another time.", o.Time, labels[o.Action]))
			return
		}
	}
	if len(cfg.Schedules) >= 100 {
		fail(w, 400, "Too many schedules")
		return
	}
	cfg.Schedules = append(cfg.Schedules, s)
	saveConfig()
	kickWake()
	reply(w, 200, s)
}

func hChangeSchedule(w http.ResponseWriter, r *http.Request) {
	var b struct{ Enabled bool }
	json.NewDecoder(r.Body).Decode(&b)
	mu.Lock()
	defer mu.Unlock()
	for i := range cfg.Schedules {
		if cfg.Schedules[i].ID != r.PathValue("id") {
			continue
		}
		if r.Method == "DELETE" {
			cfg.Schedules = append(cfg.Schedules[:i], cfg.Schedules[i+1:]...)
		} else {
			cfg.Schedules[i].Enabled = b.Enabled
			cfg.Schedules[i].LastFired = ""
		}
		saveConfig()
		kickWake()
		reply(w, 200, map[string]bool{"ok": true})
		return
	}
	fail(w, 404, "Schedule not found")
}

func common(m *http.ServeMux, wrap func(http.HandlerFunc) http.HandlerFunc) {
	m.HandleFunc("GET /api/status", wrap(hStatus))
	m.HandleFunc("POST /api/power", wrap(hPower))
	m.HandleFunc("POST /api/schedules", wrap(hAddSchedule))
	m.HandleFunc("PATCH /api/schedules/{id}", wrap(hChangeSchedule))
	m.HandleFunc("DELETE /api/schedules/{id}", wrap(hChangeSchedule))
	m.HandleFunc("POST /api/timer", wrap(hTimer))
	m.HandleFunc("DELETE /api/timer", wrap(hTimer))
	m.HandleFunc("PUT /api/automation", wrap(hAutomation))
	m.HandleFunc("POST /api/wake-peer", wrap(hWakePeer))
}

// ---- phone-facing server ----

func hPair(w http.ResponseWriter, r *http.Request) {
	ip, ok := gate(w, r, true)
	if !ok {
		return
	}
	var b struct{ Name, Nonce, Proof string }
	json.NewDecoder(r.Body).Decode(&b)
	nonce, err1 := base64.StdEncoding.DecodeString(b.Nonce)
	proof, err2 := base64.StdEncoding.DecodeString(b.Proof)
	if err1 != nil || err2 != nil || len(nonce) < 16 || len(nonce) > 64 {
		fail(w, 400, "Bad pairing request")
		return
	}
	mu.Lock()
	defer mu.Unlock()
	key := pairKey()
	if !hmac.Equal(proof, mac256(key, []byte("pcpower-pair-client-v1"), nonce)) {
		recordFail(ip)
		time.Sleep(300 * time.Millisecond)
		fail(w, http.StatusUnauthorized, "Wrong pairing code")
		return
	}
	if len(cfg.Devices) >= maxDevices {
		fail(w, http.StatusConflict, "Too many phones are paired with this PC. Remove one in the PC Power window first.")
		return
	}
	raw := make([]byte, 32)
	rand.Read(raw)
	token := base64.RawURLEncoding.EncodeToString(raw)
	name := strings.TrimSpace(b.Name)
	if name == "" {
		name = "Phone"
	}
	if len(name) > 40 {
		name = name[:40]
	}
	d := Device{ID: newID(), Name: name, TokenHash: tokenHash(token), Added: time.Now().Format("2006-01-02 15:04")}
	cfg.Devices = append(cfg.Devices, d)
	saveConfig()
	addEventLocked("pair", fmt.Sprintf("New phone paired: %s", name))
	reply(w, 200, map[string]any{"deviceId": d.ID, "token": token, "name": cfg.Name,
		"proof": base64.StdEncoding.EncodeToString(mac256(key, []byte("pcpower-pair-server-v1"), nonce, []byte(token)))})
}

func phoneRoutes() http.Handler {
	m := http.NewServeMux()
	common(m, phone)
	m.HandleFunc("POST /api/pair", hPair)
	// The only thing an unpaired device can learn: that this is PC Power, and what to call it.
	m.HandleFunc("GET /api/hello", func(w http.ResponseWriter, r *http.Request) {
		if _, ok := gate(w, r, true); !ok {
			return
		}
		mu.Lock()
		name := cfg.Name
		mu.Unlock()
		reply(w, 200, map[string]any{"app": "pcpower", "name": name, "pairing": 1})
	})
	// The phone tells the PC to forget it.
	m.HandleFunc("POST /api/unpair", phone(func(w http.ResponseWriter, r *http.Request) {
		h := tokenHash(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
		mu.Lock()
		for i, d := range cfg.Devices {
			if d.TokenHash == h {
				cfg.Devices = append(cfg.Devices[:i], cfg.Devices[i+1:]...)
				break
			}
		}
		saveConfig()
		mu.Unlock()
		reply(w, 200, map[string]bool{"ok": true})
	}))
	return m
}

// ---- this PC's own window ----

func localRoutes() http.Handler {
	m := http.NewServeMux()
	m.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
		w.Write(bytes.Replace(indexHTML, []byte("<!--LEGAL-->"), legalHTML, 1))
	})
	for _, s := range []string{"32", "192", "512"} {
		png := iconPNG[s]
		m.HandleFunc("GET /icon-"+s+".png", func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "image/png")
			w.Header().Set("Cache-Control", "max-age=86400")
			w.Write(png)
		})
	}
	common(m, local)
	m.HandleFunc("POST /api/local/presence", local(hPresence))
	// Portable copy only: install PC Power properly, as a Windows service. Windows asks for approval.
	m.HandleFunc("POST /api/local/install", local(func(w http.ResponseWriter, r *http.Request) {
		if serviceMode || !installSupported {
			fail(w, 400, "PC Power is already installed.")
			return
		}
		if err := installStart(); err != nil {
			fail(w, 500, "Could not start the installer: "+err.Error())
			return
		}
		reply(w, 200, map[string]bool{"ok": true})
		go func() { time.Sleep(700 * time.Millisecond); os.Exit(0) }() // free the ports for the service
	}))
	m.HandleFunc("GET /api/local", local(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		devs := make([]map[string]any, 0, len(cfg.Devices))
		for _, d := range cfg.Devices {
			seen := ""
			if t, ok := lastSeen[d.ID]; ok {
				seen = t.Format("2006-01-02 15:04")
			}
			devs = append(devs, map[string]any{"id": d.ID, "name": d.Name, "added": d.Added, "lastSeen": seen})
		}
		out := map[string]any{"code": prettyCode(cfg.Token), "lanOnly": *cfg.LanOnly, "devices": devs, "termsAccepted": cfg.Accepted == legalVersion,
			"installed": serviceMode, "canInstall": installSupported && !serviceMode,
			"fingerprint": hex.EncodeToString(certFP[:8])}
		mu.Unlock()
		out["autostart"], out["autostartSupported"] = autostartGet(), autostartSupported
		out["network"] = netCheck(r.URL.Query().Get("fresh") == "1")
		reply(w, 200, out)
	}))
	// One-click fixes for "my phone cannot find this PC". Only ever started by a click in this window.
	m.HandleFunc("POST /api/local/network-fix", local(func(w http.ResponseWriter, r *http.Request) {
		var b struct{ Fix string }
		json.NewDecoder(r.Body).Decode(&b)
		var err error
		switch b.Fix {
		case "private":
			idx := activeIfIndex()
			if idx == 0 {
				fail(w, 400, "Could not tell which network this PC is on.")
				return
			}
			err = makeNetworkPrivate(idx)
		case "firewall":
			err = fixFirewall()
		default:
			fail(w, 400, "Unknown fix.")
			return
		}
		if err != nil {
			fail(w, 500, err.Error())
			return
		}
		addEvent("Network settings fixed from the PC Power window ("+b.Fix+")", "")
		reply(w, 200, map[string]any{"ok": true, "message": "Done. Search for the PC again on your phone."})
	}))
	m.HandleFunc("PATCH /api/local", local(func(w http.ResponseWriter, r *http.Request) {
		var b struct {
			Name      *string
			Autostart *bool
			LanOnly   *bool
			NewCode   bool
			Accept    string // the version of the terms the user just agreed to
		}
		json.NewDecoder(r.Body).Decode(&b)
		if b.Autostart != nil {
			if err := autostartSet(*b.Autostart); err != nil {
				fail(w, 500, "Could not change the startup setting: "+err.Error())
				return
			}
		}
		mu.Lock()
		if b.Name != nil && strings.TrimSpace(*b.Name) != "" {
			cfg.Name = strings.TrimSpace(*b.Name)
			if len(cfg.Name) > 60 {
				cfg.Name = cfg.Name[:60]
			}
		}
		if b.LanOnly != nil {
			cfg.LanOnly = b.LanOnly
		}
		if b.Accept == legalVersion {
			cfg.Accepted = legalVersion
			log.Printf("terms %s accepted", legalVersion)
		}
		if b.NewCode {
			cfg.Token = newCode()
		}
		saveConfig()
		mu.Unlock()
		reply(w, 200, map[string]bool{"ok": true})
	}))
	m.HandleFunc("DELETE /api/local/devices/{id}", local(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		kept := cfg.Devices[:0]
		for _, d := range cfg.Devices {
			if d.ID != r.PathValue("id") && r.PathValue("id") != "all" {
				kept = append(kept, d)
			}
		}
		cfg.Devices = kept
		saveConfig()
		mu.Unlock()
		reply(w, 200, map[string]bool{"ok": true})
	}))
	m.HandleFunc("GET /api/local/wol", local(func(w http.ResponseWriter, r *http.Request) {
		reply(w, 200, wolCheck(r.URL.Query().Get("fresh") == "1"))
	}))
	m.HandleFunc("POST /api/local/wol/fix", local(func(w http.ResponseWriter, r *http.Request) {
		if err := wolFix(); err != nil {
			fail(w, 500, "Could not start the fix: "+err.Error())
			return
		}
		reply(w, 200, map[string]bool{"ok": true})
	}))
	// Lets a newer copy be swapped in without hunting for the tray icon.
	m.HandleFunc("POST /api/local/quit", local(func(w http.ResponseWriter, r *http.Request) {
		reply(w, 200, map[string]bool{"ok": true})
		go func() { time.Sleep(300 * time.Millisecond); os.Exit(0) }()
	}))
	return m
}

func localURL() string { return fmt.Sprintf("http://127.0.0.1:%d/", cfg.LocalPort) }

func hardened(h http.Handler) *http.Server {
	return &http.Server{Handler: h, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second,
		WriteTimeout: 15 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16 << 10,
		ErrorLog: log.New(io.Discard, "", 0)} // TLS probes from scanners would otherwise flood the log
}

var (
	dataDir     string // where config, certificate, log and the local key live
	localKey    string // required on every call to the local (127.0.0.1) API
	serviceMode bool   // the core is running as the Windows service
)

// startCore loads the settings and starts everything that does the real work: both servers, the
// scheduler and the listeners. It returns an error if PC Power is already running.
func startCore() error {
	if p := os.Getenv("PCPOWER_CONFIG"); p != "" {
		dataDir = filepath.Dir(p)
	}
	loadConfig()
	localLn, err := net.Listen("tcp4", fmt.Sprintf("127.0.0.1:%d", cfg.LocalPort))
	if err != nil {
		return err
	}
	if lf, err := os.OpenFile(filepath.Join(dataDir, "pcpower.log"), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600); err == nil && os.Getenv("PCPOWER_CONFIG") == "" {
		log.SetOutput(lf)
	}
	// In service mode the installer made the key file and limited who may read it, so keep that key.
	if _, k := readKeyFile(dataDir); serviceMode && k != "" {
		localKey = k
	} else {
		raw := make([]byte, 24)
		rand.Read(raw)
		localKey = base64.RawURLEncoding.EncodeToString(raw)
	}
	if err := os.WriteFile(filepath.Join(dataDir, "local.key"), []byte(fmt.Sprintf("%d:%s", cfg.LocalPort, localKey)), 0o600); err != nil {
		log.Printf("cannot write the local key: %v", err)
	}
	cert, err := loadOrCreateCert(dataDir)
	if err != nil {
		log.Fatalf("cannot create the encryption certificate: %v", err)
	}
	go func() {
		if err := hardened(localRoutes()).Serve(localLn); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	}()
	go func() {
		// If the port is taken (an older PC Power still closing), keep trying instead of giving up.
		for {
			ln, err := net.Listen("tcp4", fmt.Sprintf(":%d", cfg.Port))
			if err != nil {
				log.Printf("phone port %d not available yet: %v", cfg.Port, err)
				time.Sleep(5 * time.Second)
				continue
			}
			srv := hardened(phoneRoutes())
			srv.TLSConfig = &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{cert}}
			log.Printf("PC Power %q: phones on port %d (encrypted), window on %s", cfg.Name, cfg.Port, localURL())
			log.Printf("phone server stopped: %v", srv.ServeTLS(ln, "", ""))
			time.Sleep(5 * time.Second)
		}
	}()
	go scheduler()
	go discovery()
	go wakeListener()
	go wakeLoop()
	go netSampler()
	addEvent("start", "PC Power started (the PC is on)")
	return nil
}

// readKeyFile returns the local port and key written by the running core.
func readKeyFile(dir string) (port int, key string) {
	b, err := os.ReadFile(filepath.Join(dir, "local.key"))
	if err != nil {
		return 0, ""
	}
	p, k, ok := strings.Cut(strings.TrimSpace(string(b)), ":")
	if !ok {
		return 0, ""
	}
	fmt.Sscanf(p, "%d", &port)
	return port, k
}

// windowURL is the address of the app's window; the key travels in the part after # so that it is
// never sent over the network or written to a log.
func windowURL(dir string) string {
	port, key := readKeyFile(dir)
	if port == 0 {
		port = 8786
	}
	return fmt.Sprintf("http://127.0.0.1:%d/#k=%s", port, key)
}

// portableMain runs everything in this one process: used before PC Power is installed, and on
// systems other than Windows.
func portableMain(background bool) {
	if err := startCore(); err != nil {
		// Almost always: PC Power is already running. Show its window instead of starting twice.
		openWindow(windowURL(dataDir))
		return
	}
	helperDir = dataDir
	go helperLoop()
	if autostartGet() {
		autostartSet(true)
	}
	if !background {
		openWindow(windowURL(dataDir))
	}
	runTray() // blocks until Quit
}

func main() { platformMain() }

// ---- wake signal test ----
//
// While the PC is on, it listens for the same wake signal that would turn it on. That lets the phone
// check, from outside, that the router setup really delivers the signal, with no server in between.

var wakeSeen struct {
	sync.Mutex
	at        time.Time
	outside   bool // it came from a public address, so the router forwarded it from the internet
	listening bool
}

func ownMACs() [][]byte {
	var out [][]byte
	ifaces, _ := net.Interfaces()
	for _, i := range ifaces {
		if len(i.HardwareAddr) == 6 {
			out = append(out, i.HardwareAddr)
		}
	}
	return out
}

// isMagicFor reports whether p holds a wake packet for mac: six 0xFF bytes, then the address 16 times.
func isMagicFor(p, mac []byte) bool {
	for i := 0; i+102 <= len(p); i++ {
		ok := true
		for k := 0; k < 6 && ok; k++ {
			ok = p[i+k] == 0xff
		}
		for k := 0; k < 96 && ok; k++ {
			ok = p[i+6+k] == mac[k%6]
		}
		if ok {
			return true
		}
	}
	return false
}

func wakeListener() {
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{Port: 9})
	if err != nil {
		log.Printf("wake test unavailable (cannot listen on UDP 9): %v", err)
		return
	}
	wakeSeen.Lock()
	wakeSeen.listening = true
	wakeSeen.Unlock()
	buf := make([]byte, 1024)
	for {
		n, addr, err := conn.ReadFromUDP(buf)
		if err != nil {
			return
		}
		for _, mac := range ownMACs() {
			if isMagicFor(buf[:n], mac) {
				wakeSeen.Lock()
				wakeSeen.at, wakeSeen.outside = time.Now(), !onLocalNetwork(addr.IP)
				wakeSeen.Unlock()
				break
			}
		}
	}
}

func wakeTestStatus() map[string]any {
	wakeSeen.Lock()
	defer wakeSeen.Unlock()
	out := map[string]any{"available": wakeSeen.listening}
	if !wakeSeen.at.IsZero() && time.Since(wakeSeen.at) < 30*time.Minute {
		out["secondsAgo"], out["outside"] = int(time.Since(wakeSeen.at).Seconds()), wakeSeen.outside
	}
	return out
}
