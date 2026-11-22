//go:build windows

package main

// Installing PC Power properly: the core runs as a Windows service, so it is there before anyone
// signs in (a PC woken remotely can still be shut down), and a small tray helper runs for each user.
//
//   PCPower.exe                    first run: works at once as a portable app, and offers to install
//   PCPower.exe --install          (administrator) copy to Program Files, create the service, firewall rule
//   PCPower.exe --uninstall        (administrator) remove everything, including settings
//   PCPower.exe --service          started by Windows: the core
//   PCPower.exe [--background]     once installed: the tray helper

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
)

const (
	installSupported = true
	serviceName      = "PCPower"
	appVersion       = "2.5.0"
	uninstallKey     = `Software\Microsoft\Windows\CurrentVersion\Uninstall\PCPower`
	machineRunKey    = `Software\Microsoft\Windows\CurrentVersion\Run`
	firewallRule     = "PC Power"
)

func programDir() string { return filepath.Join(os.Getenv("ProgramFiles"), "PC Power") }
func machineDataDir() string {
	return filepath.Join(os.Getenv("ProgramData"), "PCPower")
}

func serviceInstalled() bool {
	k, err := registry.OpenKey(registry.LOCAL_MACHINE, `SYSTEM\CurrentControlSet\Services\`+serviceName, registry.QUERY_VALUE)
	if err != nil {
		return false
	}
	k.Close()
	return true
}

func messageBox(text string, isError bool) {
	t, _ := windows.UTF16PtrFromString(text)
	c, _ := windows.UTF16PtrFromString("PC Power")
	flags := uint32(0x40) // information icon
	if isError {
		flags = 0x10
	}
	windows.MessageBox(0, t, c, flags)
}

func platformMain() {
	background := flag.Bool("background", false, "start in the tray without opening the window")
	install := flag.Bool("install", false, "install PC Power (needs administrator rights)")
	uninstall := flag.Bool("uninstall", false, "remove PC Power (needs administrator rights)")
	service := flag.Bool("service", false, "run as the Windows service")
	forUser := flag.String("for-user", "", "account that may control PC Power from this PC")
	fromDir := flag.String("from-dir", "", "settings folder of a portable copy to carry over")
	quiet := flag.Bool("quiet", false, "no message boxes")
	dry := flag.Bool("dry-run", false, "testing: log power actions instead of doing them")
	flag.Parse()

	isSvc, _ := svc.IsWindowsService()
	switch {
	case *install:
		err := doInstall(*forUser, *fromDir, *dry)
		report("PC Power is installed.\n\nIt now runs in the background, even before anyone signs in. Look for its icon near the clock.", err, *quiet)
		if err == nil && !*quiet {
			// Start the tray helper as the normal desktop user, not as administrator.
			hidden("explorer.exe", filepath.Join(programDir(), "PCPower.exe")).Start()
		}
	case *uninstall:
		report("PC Power has been removed.", doUninstall(), *quiet)
	case isSvc || *service:
		runService()
	case serviceInstalled():
		helperMain(*background)
	default:
		dataDir = userDataDir()
		portableMain(*background)
	}
}

func report(okText string, err error, quiet bool) {
	if err != nil {
		log.Printf("failed: %v", err)
		if !quiet {
			messageBox("That did not work:\n\n"+err.Error(), true)
		}
		os.Exit(1)
	}
	if !quiet {
		messageBox(okText, false)
	}
}

// ---- the service ----

type coreService struct{}

func (coreService) Execute(_ []string, req <-chan svc.ChangeRequest, status chan<- svc.Status) (bool, uint32) {
	status <- svc.Status{State: svc.StartPending}
	serviceMode = true
	dataDir = machineDataDir()
	if err := startCore(); err != nil {
		log.Printf("cannot start: %v", err)
		return true, 1
	}
	status <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	for c := range req {
		switch c.Cmd {
		case svc.Interrogate:
			status <- c.CurrentStatus
		case svc.Stop, svc.Shutdown:
			status <- svc.Status{State: svc.StopPending}
			return false, 0
		}
	}
	return false, 0
}

func runService() {
	os.MkdirAll(machineDataDir(), 0o700)
	if isSvc, _ := svc.IsWindowsService(); !isSvc {
		// Started by hand with --service (for debugging): run the core in the foreground.
		serviceMode, dataDir = true, machineDataDir()
		if err := startCore(); err != nil {
			log.Fatal(err)
		}
		select {}
	}
	if err := svc.Run(serviceName, coreService{}); err != nil {
		log.Printf("service failed: %v", err)
	}
}

// ---- the tray helper (once installed) ----

func helperMain(background bool) {
	trayOnly = true
	helperDir = machineDataDir()
	// One helper per signed-in user: a second start just shows the window.
	name, _ := windows.UTF16PtrFromString("Local\\PCPowerHelper")
	if _, err := windows.CreateMutex(nil, false, name); err == windows.ERROR_ALREADY_EXISTS {
		openWindow(windowURL(helperDir))
		return
	}
	autostartSet(false) // the old per-user startup entry of the portable copy is no longer needed
	if _, key := readKeyFile(helperDir); key == "" {
		if background {
			return // signing in to another account on a shared PC: stay out of the way
		}
		messageBox("PC Power is installed on this PC, but this Windows account is not allowed to control it.\n\nSign in with the account that installed it, or install it again from this account.", true)
		return
	}
	go helperLoop()
	if !background {
		openWindow(windowURL(helperDir))
	}
	runTray()
}

// ---- install and uninstall ----

func isAdmin() bool {
	return windows.GetCurrentProcessToken().IsElevated()
}

// installStart is called from the portable app's window: it starts this program again as
// administrator (Windows shows its approval prompt) to do the installation.
func installStart() error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	user := os.Getenv("USERDOMAIN") + `\` + os.Getenv("USERNAME")
	args := fmt.Sprintf(`--install --for-user "%s" --from-dir "%s"`, user, dataDir)
	verb, _ := windows.UTF16PtrFromString("runas")
	file, _ := windows.UTF16PtrFromString(exe)
	a, _ := windows.UTF16PtrFromString(args)
	return windows.ShellExecute(0, verb, file, a, nil, windows.SW_SHOWNORMAL)
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

func run(name string, args ...string) error {
	out, err := hidden(name, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s: %v: %s", name, err, strings.TrimSpace(string(out)))
	}
	return nil
}

func stopService(m *mgr.Mgr) {
	s, err := m.OpenService(serviceName)
	if err != nil {
		return
	}
	defer s.Close()
	s.Control(svc.Stop)
	for i := 0; i < 40; i++ {
		if st, err := s.Query(); err != nil || st.State == svc.Stopped {
			return
		}
		time.Sleep(250 * time.Millisecond)
	}
}

func doInstall(forUser, fromDir string, dry bool) error {
	if !isAdmin() {
		return errors.New("installing needs administrator rights")
	}
	data, prog := machineDataDir(), programDir()
	os.MkdirAll(data, 0o700)
	if lf, err := os.OpenFile(filepath.Join(data, "install.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600); err == nil {
		log.SetOutput(lf)
	}
	log.Printf("installing %s for %q", appVersion, forUser)
	time.Sleep(1500 * time.Millisecond) // let a portable copy that started us finish closing

	m, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("cannot reach the Windows service manager: %w", err)
	}
	defer m.Disconnect()
	stopService(m) // upgrading: free the program file

	// 1. The program.
	self, err := os.Executable()
	if err != nil {
		return err
	}
	dst := filepath.Join(prog, "PCPower.exe")
	if err := os.MkdirAll(prog, 0o755); err != nil {
		return err
	}
	if !strings.EqualFold(filepath.Clean(self), filepath.Clean(dst)) {
		if err := copyFile(self, dst); err != nil {
			return fmt.Errorf("cannot copy the program to %s: %w", prog, err)
		}
	}

	// 2. Settings: carry over a portable copy's schedules, paired phones and certificate once.
	if _, err := os.Stat(filepath.Join(data, "config.json")); err != nil && fromDir != "" {
		for _, f := range []string{"config.json", "cert.pem", "key.pem"} {
			if err := copyFile(filepath.Join(fromDir, f), filepath.Join(data, f)); err != nil {
				log.Printf("not carried over: %s (%v)", f, err)
			}
		}
	}
	if dry {
		os.WriteFile(filepath.Join(data, "dryrun"), []byte("1"), 0o600)
	}

	// 3. The local key, and who may read it. Only that account can control PC Power from this PC.
	keyFile := filepath.Join(data, "local.key")
	if _, k := readKeyFile(data); k == "" {
		os.WriteFile(keyFile, []byte("8786:"+newID()+newID()+newID()), 0o600)
	}
	if err := run("icacls", data, "/inheritance:r", "/grant:r", "*S-1-5-18:(OI)(CI)F", "*S-1-5-32-544:(OI)(CI)F"); err != nil {
		return err
	}
	if forUser != "" {
		// The helper only needs to find and read the key file.
		if err := run("icacls", data, "/grant", forUser+":(RX)"); err != nil {
			log.Printf("could not grant folder access to %s: %v", forUser, err)
		}
		if err := run("icacls", keyFile, "/grant", forUser+":(R)"); err != nil {
			log.Printf("could not grant key access to %s: %v", forUser, err)
		}
	}

	// 4. The service.
	if s, err := m.OpenService(serviceName); err == nil {
		s.Delete()
		s.Close()
		time.Sleep(time.Second)
	}
	s, err := m.CreateService(serviceName, dst, mgr.Config{
		DisplayName: "PC Power",
		Description: "Runs PC Power's schedules and lets paired phones control this PC.",
		StartType:   mgr.StartAutomatic,
	}, "--service")
	if err != nil {
		return fmt.Errorf("cannot create the service: %w", err)
	}
	defer s.Close()
	s.SetRecoveryActions([]mgr.RecoveryAction{
		{Type: mgr.ServiceRestart, Delay: 10 * time.Second},
		{Type: mgr.ServiceRestart, Delay: time.Minute},
	}, 86400)
	if err := s.Start(); err != nil {
		return fmt.Errorf("cannot start the service: %w", err)
	}

	// 5. Firewall: let phones on private networks reach it. Never on public networks.
	hidden("netsh", "advfirewall", "firewall", "delete", "rule", "name="+firewallRule).Run()
	if err := run("netsh", "advfirewall", "firewall", "add", "rule", "name="+firewallRule, "dir=in", "action=allow",
		"program="+dst, "profile=private,domain", "enable=yes"); err != nil {
		log.Printf("firewall rule not added: %v", err)
	}

	// 6. Tray helper at sign-in for every user, an entry in "Installed apps", a Start menu shortcut.
	if k, _, err := registry.CreateKey(registry.LOCAL_MACHINE, machineRunKey, registry.SET_VALUE); err == nil {
		k.SetStringValue("PCPower", `"`+dst+`" --background`)
		k.Close()
	}
	if k, _, err := registry.CreateKey(registry.LOCAL_MACHINE, uninstallKey, registry.SET_VALUE); err == nil {
		k.SetStringValue("DisplayName", "PC Power")
		k.SetStringValue("DisplayVersion", appVersion)
		k.SetStringValue("Publisher", "Mogamat Muneer Miller")
		k.SetStringValue("DisplayIcon", dst)
		k.SetStringValue("InstallLocation", prog)
		k.SetStringValue("UninstallString", `"`+dst+`" --uninstall`)
		k.SetDWordValue("NoModify", 1)
		k.SetDWordValue("NoRepair", 1)
		k.Close()
	}
	link := filepath.Join(os.Getenv("ProgramData"), `Microsoft\Windows\Start Menu\Programs\PC Power.lnk`)
	script := fmt.Sprintf("$s=(New-Object -ComObject WScript.Shell).CreateShortcut('%s');$s.TargetPath='%s';$s.Description='Schedule when this PC turns off and on';$s.Save()",
		strings.ReplaceAll(link, "'", "''"), strings.ReplaceAll(dst, "'", "''"))
	if err := run("powershell.exe", "-NoProfile", "-NonInteractive", "-EncodedCommand", encodePS(script)); err != nil {
		log.Printf("Start menu shortcut not created: %v", err)
	}
	log.Printf("installed")
	return nil
}

func doUninstall() error {
	if !isAdmin() {
		// Started from "Installed apps" without rights: ask Windows to run it again as administrator.
		exe, _ := os.Executable()
		verb, _ := windows.UTF16PtrFromString("runas")
		file, _ := windows.UTF16PtrFromString(exe)
		a, _ := windows.UTF16PtrFromString("--uninstall")
		if err := windows.ShellExecute(0, verb, file, a, nil, windows.SW_SHOWNORMAL); err != nil {
			return err
		}
		os.Exit(0)
	}
	if m, err := mgr.Connect(); err == nil {
		stopService(m)
		if s, err := m.OpenService(serviceName); err == nil {
			s.Delete()
			s.Close()
		}
		m.Disconnect()
	}
	hidden("taskkill", "/F", "/IM", "PCPower.exe", "/FI", fmt.Sprintf("PID ne %d", os.Getpid())).Run() // tray helpers
	hidden("netsh", "advfirewall", "firewall", "delete", "rule", "name="+firewallRule).Run()
	if k, err := registry.OpenKey(registry.LOCAL_MACHINE, machineRunKey, registry.SET_VALUE); err == nil {
		k.DeleteValue("PCPower")
		k.Close()
	}
	registry.DeleteKey(registry.LOCAL_MACHINE, uninstallKey)
	os.Remove(filepath.Join(os.Getenv("ProgramData"), `Microsoft\Windows\Start Menu\Programs\PC Power.lnk`))
	os.RemoveAll(machineDataDir()) // settings, paired phones, certificate, logs
	// A running program cannot delete its own file, so hand the last step to a short command.
	prog := programDir()
	c := exec.Command(filepath.Join(os.Getenv("SystemRoot"), "System32", "cmd.exe"))
	// cmd.exe has its own quoting rules, so the command line is given exactly as it must arrive.
	c.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CmdLine: `cmd.exe /d /c "ping -n 4 127.0.0.1 >nul & rmdir /s /q "` + prog + `""`}
	c.Dir = os.Getenv("SystemRoot")
	c.Start()
	return nil
}

var _ = unsafe.Sizeof(0)
