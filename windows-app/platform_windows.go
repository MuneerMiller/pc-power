//go:build windows

package main

import (
	_ "embed"
	"encoding/base64"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode/utf16"
	"unsafe"

	"fyne.io/systray"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

//go:embed icon.ico
var iconICO []byte

const (
	autostartSupported = true
	runKey             = `Software\Microsoft\Windows\CurrentVersion\Run`
	runName            = "PCPower"
	warning            = "PC Power: this PC will turn off in 60 seconds. Open PC Power and press Cancel to stop it."
)

// hidden runs a console program without flashing a console window.
func hidden(name string, args ...string) *exec.Cmd {
	c := exec.Command(name, args...)
	c.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000} // CREATE_NO_WINDOW
	return c
}

func doPower(action string) error {
	switch action {
	case "shutdown":
		return hidden("shutdown", "/s", "/t", "60", "/c", warning).Run()
	case "restart":
		return hidden("shutdown", "/r", "/t", "60", "/c", "PC Power: this PC will restart in 60 seconds. Open PC Power and press Cancel to stop it.").Run()
	case "hibernate":
		return hidden("shutdown", "/h").Run()
	case "cancel":
		hidden("shutdown", "/a").Run() // exits non-zero when nothing was pending; that is fine
		return nil
	case "sleep":
		// SetSuspendState(hibernate=false, force=false, wakeEventsDisabled=false)
		r, _, err := syscall.NewLazyDLL("powrprof.dll").NewProc("SetSuspendState").Call(0, 0, 0)
		if r == 0 {
			return err
		}
	}
	return nil
}

// canHibernate reads whether Windows has hibernation switched on (powercfg /h).
func canHibernate() bool {
	k, err := registry.OpenKey(registry.LOCAL_MACHINE, `SYSTEM\CurrentControlSet\Control\Power`, registry.QUERY_VALUE)
	if err != nil {
		return true
	}
	defer k.Close()
	v, _, err := k.GetIntegerValue("HibernateEnabled")
	return err != nil || v == 1
}

func autostartGet() bool {
	k, err := registry.OpenKey(registry.CURRENT_USER, runKey, registry.QUERY_VALUE)
	if err != nil {
		return false
	}
	defer k.Close()
	_, _, err = k.GetStringValue(runName)
	return err == nil
}

func autostartSet(on bool) error {
	k, _, err := registry.CreateKey(registry.CURRENT_USER, runKey, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer k.Close()
	if !on {
		if err := k.DeleteValue(runName); err != nil && err != registry.ErrNotExist {
			return err
		}
		return nil
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	return k.SetStringValue(runName, `"`+exe+`" --background`)
}

// openWindow shows the app in its own window (Edge app mode), falling back to the default browser.
func openWindow(url string) {
	for _, base := range []string{os.Getenv("ProgramFiles(x86)"), os.Getenv("ProgramFiles")} {
		edge := filepath.Join(base, "Microsoft", "Edge", "Application", "msedge.exe")
		if _, err := os.Stat(edge); base != "" && err == nil {
			if exec.Command(edge, "--app="+url, "--window-size=480,860").Start() == nil {
				return
			}
		}
	}
	hidden("rundll32", "url.dll,FileProtocolHandler", url).Start()
}

func runTray() {
	systray.Run(func() {
		systray.SetIcon(iconICO)
		systray.SetTitle("PC Power")
		systray.SetTooltip("PC Power")
		open := systray.AddMenuItem("Open PC Power", "Schedules, power and phone pairing")
		cancel := systray.AddMenuItem("Cancel pending shutdown", "Stops a shutdown or restart that is counting down")
		systray.AddSeparator()
		quitTip := "Stop PC Power (schedules will not run)"
		if trayOnly {
			quitTip = "Hide the tray icon. PC Power keeps running in the background."
		}
		quit := systray.AddMenuItem("Quit", quitTip)
		go func() {
			for {
				select {
				case <-open.ClickedCh:
					openWindow(windowURL(helperDir))
				case <-cancel.ClickedCh:
					localCall("POST", "/api/power", map[string]string{"action": "cancel"})
				case <-quit.ClickedCh:
					systray.Quit()
				}
			}
		}()
	}, func() { os.Exit(0) })
}

// encodePS packs a script for powershell -EncodedCommand, which avoids every quoting problem.
func encodePS(script string) string {
	u := utf16.Encode([]rune(script))
	b := make([]byte, len(u)*2)
	for i, c := range u {
		b[i*2], b[i*2+1] = byte(c), byte(c>>8)
	}
	return base64.StdEncoding.EncodeToString(b)
}

const netClass = `SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}`

// activeAdapter finds the network card this PC is using right now (the one with our MAC address) and
// reports its Windows ID and whether it is Wi-Fi.
func activeAdapter() (guid string, wifi, found bool) {
	_, mac, _ := netInfo()
	if mac == "" {
		return "", false, false
	}
	size := uint32(16 * 1024)
	for tries := 0; tries < 3; tries++ {
		buf := make([]byte, size)
		first := (*windows.IpAdapterAddresses)(unsafe.Pointer(&buf[0]))
		err := windows.GetAdaptersAddresses(windows.AF_UNSPEC, windows.GAA_FLAG_SKIP_ANYCAST|windows.GAA_FLAG_SKIP_MULTICAST|windows.GAA_FLAG_SKIP_DNS_SERVER, 0, first, &size)
		if err == windows.ERROR_BUFFER_OVERFLOW {
			continue // size now holds what is needed
		}
		if err != nil {
			return "", false, false
		}
		for a := first; a != nil; a = a.Next {
			if a.PhysicalAddressLength != 6 || net.HardwareAddr(a.PhysicalAddress[:6]).String() != mac {
				continue
			}
			const ifTypeWifi = 71 // IF_TYPE_IEEE80211
			return strings.ToUpper(windows.BytePtrToString(a.AdapterName)), a.IfType == ifTypeWifi, true
		}
		return "", false, false
	}
	return "", false, false
}

// wolRead reads the wake settings of the network cards from the registry, where the driver keeps them
// under standard names. Unlike the PowerShell power-management cmdlets, this needs no admin rights.
// It lists every wired card that can wake the PC, plus the Wi-Fi card if that is what the PC is using.
func wolRead() WolReport {
	r := WolReport{Supported: true, Adapters: []WolAdapter{}}
	if k, err := registry.OpenKey(registry.LOCAL_MACHINE, `SYSTEM\CurrentControlSet\Control\Session Manager\Power`, registry.QUERY_VALUE); err == nil {
		v, _, err := k.GetIntegerValue("HiberbootEnabled")
		r.FastStartup = err == nil && v == 1
		k.Close()
	}
	activeGUID, activeWifi, haveActive := activeAdapter()
	if haveActive {
		r.Connection = "ethernet"
		if activeWifi {
			r.Connection = "wifi"
		}
	}
	r.WakeTimers = wakeTimerPolicy()
	root, err := registry.OpenKey(registry.LOCAL_MACHINE, netClass, registry.ENUMERATE_SUB_KEYS)
	if err != nil {
		r.Error = "Could not read the network card settings: " + err.Error()
		return r
	}
	defer root.Close()
	names, _ := root.ReadSubKeyNames(-1)
	onOff := func(k registry.Key, name string) string {
		v, _, err := k.GetStringValue(name)
		if err != nil {
			return "Unsupported"
		}
		if strings.TrimSpace(v) == "1" {
			return "Enabled"
		}
		return "Disabled"
	}
	for _, n := range names {
		k, err := registry.OpenKey(registry.LOCAL_MACHINE, netClass+`\`+n, registry.QUERY_VALUE)
		if err != nil {
			continue // "Properties" and other protected subkeys
		}
		desc, _, _ := k.GetStringValue("DriverDesc")
		media, _, _ := k.GetStringValue("*PhysicalMediaType")
		id, _, _ := k.GetStringValue("NetCfgInstanceId")
		active := haveActive && strings.ToUpper(id) == activeGUID
		wifi := media == "9" || (active && activeWifi) // 9 = Wi-Fi, 14 = Ethernet
		magic := onOff(k, "*WakeOnMagicPacket")
		virtual := desc == "" || strings.Contains(desc, "Virtual")
		wired := !wifi && magic != "Unsupported" && (media == "14" || media == "")
		// Wired cards that can wake the PC, and the Wi-Fi card when it is the one in use.
		if !virtual && (wired || (wifi && active)) {
			r.Adapters = append(r.Adapters, WolAdapter{Name: desc, Magic: magic, Pattern: onOff(k, "*WakeOnPattern"), Wifi: wifi, Active: active})
		}
		k.Close()
	}
	return r
}

const wolFixScript = `Get-NetAdapter -Physical | ForEach-Object {
  try { Set-NetAdapterAdvancedProperty -Name $_.Name -RegistryKeyword '*WakeOnMagicPacket' -RegistryValue 1 -ErrorAction Stop } catch {}
  try { Set-NetAdapterAdvancedProperty -Name $_.Name -RegistryKeyword '*WakeOnPattern' -RegistryValue 0 -ErrorAction Stop } catch {}
  try { Set-NetAdapterPowerManagement -Name $_.Name -WakeOnMagicPacket Enabled -WakeOnPattern Disabled -ErrorAction Stop } catch {}
}
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f | Out-Null
powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 1
powercfg /setdcvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 1
powercfg /setactive SCHEME_CURRENT`

// wolFix applies the settings as administrator. Windows shows its own "allow changes?" prompt first.
func wolFix() error {
	if serviceMode { // the service already has the rights; there is no desktop to show a prompt on
		err := hidden("powershell.exe", "-NoProfile", "-NonInteractive", "-EncodedCommand", encodePS(wolFixScript)).Start()
		wolMu.Lock()
		wolCache = nil
		wolMu.Unlock()
		return err
	}
	verb, _ := windows.UTF16PtrFromString("runas")
	exe, _ := windows.UTF16PtrFromString("powershell.exe")
	args, _ := windows.UTF16PtrFromString("-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand " + encodePS(wolFixScript))
	err := windows.ShellExecute(0, verb, exe, args, nil, windows.SW_HIDE)
	wolMu.Lock()
	wolCache = nil
	wolMu.Unlock()
	return err
}

// ---- scheduled turn-on: a Windows wake timer ----

const wakeSupported = true

var (
	kernel32        = syscall.NewLazyDLL("kernel32.dll")
	procCreateTimer = kernel32.NewProc("CreateWaitableTimerW")
	procSetTimer    = kernel32.NewProc("SetWaitableTimer")
	procCancelTimer = kernel32.NewProc("CancelWaitableTimer")
	procExecState   = kernel32.NewProc("SetThreadExecutionState")
	wakeTimer       uintptr
	hexRe           = regexp.MustCompile(`0x[0-9a-fA-F]{8}`)
)

// wakeInit creates the timer and returns a channel that gets a value each time it goes off.
func wakeInit() <-chan struct{} {
	fired := make(chan struct{}, 1)
	h, _, _ := procCreateTimer.Call(0, 0, 0) // auto-reset, unnamed
	wakeTimer = h
	if h == 0 {
		return fired
	}
	go func() {
		for {
			r, err := windows.WaitForSingleObject(windows.Handle(h), windows.INFINITE)
			if err != nil || r != windows.WAIT_OBJECT_0 {
				time.Sleep(5 * time.Second)
				continue
			}
			select {
			case fired <- struct{}{}:
			default:
			}
		}
	}()
	return fired
}

// wakeArm asks Windows to wake the PC at t (from sleep or hibernate). A zero t cancels.
func wakeArm(t time.Time) error {
	if wakeTimer == 0 {
		return errors.New("Windows would not create a wake timer")
	}
	if t.IsZero() {
		procCancelTimer.Call(wakeTimer)
		return nil
	}
	due := t.UnixNano()/100 + 116444736000000000                                       // 100 ns steps since 1601, positive = an exact time
	r, _, e := procSetTimer.Call(wakeTimer, uintptr(unsafe.Pointer(&due)), 0, 0, 0, 1) // last 1 = wake the PC
	if r == 0 {
		return e
	}
	if errno, ok := e.(syscall.Errno); ok && errno == 50 { // ERROR_NOT_SUPPORTED
		return errors.New("this PC's hardware cannot wake itself on a timer")
	}
	return nil
}

// wakeKeepOn turns the screen on and stops Windows putting the PC straight back to sleep, which it
// otherwise does two minutes after a wake nobody was there for.
func wakeKeepOn(d time.Duration) {
	go func() {
		runtime.LockOSThread() // the "stay awake" request belongs to this thread
		defer runtime.UnlockOSThread()
		const continuous, systemRequired, displayRequired = 0x80000000, 0x1, 0x2
		procExecState.Call(systemRequired | displayRequired)
		procExecState.Call(continuous | systemRequired)
		time.Sleep(d)
		procExecState.Call(continuous)
	}()
}

// wakeTimerPolicy reads Windows' "Allow wake timers" setting for mains power.
func wakeTimerPolicy() string {
	out, err := hidden("powercfg", "/query", "SCHEME_CURRENT", "SUB_SLEEP", "RTCWAKE").Output()
	if err != nil {
		return ""
	}
	v := hexRe.FindAllString(string(out), -1) // the last two numbers are the mains and battery values
	if len(v) < 2 {
		return ""
	}
	switch v[len(v)-2] {
	case "0x00000000":
		return "Disabled"
	case "0x00000001":
		return "Enabled"
	case "0x00000002":
		return "ImportantOnly"
	}
	return ""
}

// ---- what the user's session is doing (called by the tray helper) ----

var (
	user32               = syscall.NewLazyDLL("user32.dll")
	shell32              = syscall.NewLazyDLL("shell32.dll")
	procGetLastInputInfo = user32.NewProc("GetLastInputInfo")
	procLockWorkStation  = user32.NewProc("LockWorkStation")
	procPostMessage      = user32.NewProc("PostMessageW")
	procKeybdEvent       = user32.NewProc("keybd_event")
	procGetTickCount     = kernel32.NewProc("GetTickCount")
	procQueryNotifyState = shell32.NewProc("SHQueryUserNotificationState")
	trayOnly             bool // this process is only the tray helper; the service does the work
	blockerRe            = regexp.MustCompile(`(?m)^\[(PROCESS|SERVICE)\]\s+(.+)$`)
)

func sessionIdleSeconds() int {
	var info struct {
		Size uint32
		Time uint32
	}
	info.Size = uint32(unsafe.Sizeof(info))
	if r, _, _ := procGetLastInputInfo.Call(uintptr(unsafe.Pointer(&info))); r == 0 {
		return 0
	}
	now, _, _ := procGetTickCount.Call()
	return int((uint32(now) - info.Time) / 1000)
}

// sessionFullscreen reports a full-screen app, game or presentation in the foreground.
func sessionFullscreen() bool {
	var state uint32
	if hr, _, _ := procQueryNotifyState.Call(uintptr(unsafe.Pointer(&state))); hr != 0 {
		return false
	}
	return state == 2 || state == 3 || state == 4 // busy (full screen), Direct3D full screen, presentation mode
}

func sessionRun(cmd string) {
	switch cmd {
	case "lock":
		procLockWorkStation.Call()
	case "displayoff":
		// HWND_BROADCAST, WM_SYSCOMMAND, SC_MONITORPOWER, 2 = off
		procPostMessage.Call(0xffff, 0x0112, 0xf170, 2)
	case "mute":
		const vkVolumeMute, keyUp = 0xAD, 0x2
		procKeybdEvent.Call(vkVolumeMute, 0, 0, 0)
		procKeybdEvent.Call(vkVolumeMute, 0, keyUp, 0)
	}
}

// powerRequests lists the programs that have asked Windows to stay awake: playing media, downloading,
// backing up and so on. Windows only shows this to administrators, so it works once installed.
func powerRequests() []string {
	out, err := hidden("powercfg", "/requests").Output()
	if err != nil {
		return nil
	}
	seen, list := map[string]bool{}, []string{}
	for _, m := range blockerRe.FindAllStringSubmatch(strings.ReplaceAll(string(out), "\r", ""), -1) {
		name := strings.TrimSpace(m[2])
		if i := strings.LastIndexAny(name, `\/`); i >= 0 {
			name = name[i+1:]
		}
		if name == "" || strings.Contains(strings.ToLower(name), "pcpower") || seen[name] {
			continue
		}
		seen[name] = true
		list = append(list, name)
		if len(list) == 3 {
			break
		}
	}
	return list
}

// netBytes returns the total bytes received and sent so far, from "netstat -e".
func netBytes() (uint64, bool) {
	out, err := hidden("netstat", "-e").Output()
	if err != nil {
		return 0, false
	}
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) < 3 {
			continue
		}
		a, err1 := strconv.ParseUint(f[len(f)-2], 10, 64)
		b, err2 := strconv.ParseUint(f[len(f)-1], 10, 64)
		if err1 == nil && err2 == nil {
			return a + b, true // the first numeric row is the byte counters
		}
	}
	return 0, false
}

// ---- network type and firewall (why a phone cannot find this PC) ----

func powershell(script string) *exec.Cmd {
	return hidden(filepath.Join(os.Getenv("SystemRoot"), `System32\WindowsPowerShell\v1.0\powershell.exe`),
		"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script)
}

// networkCategory reports whether Windows treats the network on card ifIndex as public or private.
func networkCategory(ifIndex int) (category, name string) {
	out, err := powershell(fmt.Sprintf(`$p = Get-NetConnectionProfile -InterfaceIndex %d -ErrorAction Stop | Select-Object -First 1; [string]$p.NetworkCategory + '|' + $p.Name`, ifIndex)).Output()
	if err != nil {
		return "", ""
	}
	cat, nm, _ := strings.Cut(strings.TrimSpace(string(out)), "|")
	switch strings.ToLower(cat) {
	case "public":
		return "public", nm
	case "private":
		return "private", nm
	case "domainauthenticated":
		return "domain", nm
	}
	return "", nm
}

// firewallState checks the installed copy's firewall rule. A portable copy relies on the rule Windows
// made when it first asked, which cannot be checked reliably, so it says "unknown".
func firewallState() string {
	if !serviceMode {
		return "unknown"
	}
	if hidden("netsh", "advfirewall", "firewall", "show", "rule", "name="+firewallRule).Run() != nil {
		return "missing"
	}
	return "ok"
}

func fixFirewall() error {
	if !serviceMode {
		return errors.New("only the installed PC Power can repair its firewall rule")
	}
	exe, _ := os.Executable()
	hidden("netsh", "advfirewall", "firewall", "delete", "rule", "name="+firewallRule).Run()
	out, err := hidden("netsh", "advfirewall", "firewall", "add", "rule", "name="+firewallRule, "dir=in", "action=allow",
		"program="+exe, "profile=private,domain", "enable=yes").CombinedOutput()
	if err != nil {
		return fmt.Errorf("could not add the firewall rule: %s", strings.TrimSpace(string(out)))
	}
	return nil
}

// makeNetworkPrivate tells Windows this is a trusted (home) network. The installed copy runs as a
// service and can do it directly; a portable copy asks Windows for permission first.
func makeNetworkPrivate(ifIndex int) error {
	script := fmt.Sprintf("Set-NetConnectionProfile -InterfaceIndex %d -NetworkCategory Private", ifIndex)
	if serviceMode {
		if out, err := powershell(script).CombinedOutput(); err != nil {
			return fmt.Errorf("Windows did not change it: %s", strings.TrimSpace(string(out)))
		}
		return nil
	}
	verb, _ := windows.UTF16PtrFromString("runas")
	file, _ := windows.UTF16PtrFromString(filepath.Join(os.Getenv("SystemRoot"), `System32\WindowsPowerShell\v1.0\powershell.exe`))
	args, _ := windows.UTF16PtrFromString("-NoProfile -WindowStyle Hidden -Command " + script)
	return windows.ShellExecute(0, verb, file, args, nil, windows.SW_HIDE)
}
