package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"syscall"

	"company-proxy-auto/internal/config"
	"company-proxy-auto/internal/embedded"
	"company-proxy-auto/internal/service"
)

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(1)
	}

	switch os.Args[1] {
	case "start":
		cmdStart()
	case "stop":
		cmdStop()
	case "status":
		cmdStatus()
	case "reload":
		cmdReload()
	case "config":
		cmdConfig()
	case "domains":
		cmdDomains()
	case "dashboard":
		cmdDashboard()
	case "install":
		cmdInstall()
	case "uninstall":
		cmdUninstall()
	case "help", "-h", "--help":
		printUsage()
	case "version", "-v", "--version":
		fmt.Println("company-proxy-auto v1.0.0")
	default:
		fmt.Fprintf(os.Stderr, "Unknown command: %s\n\n", os.Args[1])
		printUsage()
		os.Exit(1)
	}
}

func printUsage() {
	fmt.Print(`company-proxy-auto - Smart local proxy with domain-based routing

Usage:
  proxy <command> [options]

Commands:
  start [--dashboard]    Start proxy daemon
  stop                   Stop proxy daemon
  status                 Show proxy status and statistics
  reload                 Reload configuration without restart
  config show            Show current configuration
  config set <key> <val> Set a configuration value
  config reset           Reset to default configuration
  domains list           List all whitelisted domains
  domains add <grp> <d>  Add domain to a group
  domains remove <d>     Remove domain from all groups
  dashboard on           Activate dashboard
  dashboard off          Deactivate dashboard
  install [--cli|--full] Install as startup service
  uninstall              Remove service and clean up
  version                Show version
  help                   Show this help

`)
}

func cmdStart() {
	cfg, err := config.Load(embedded.DefaultConfigJSON)
	if err != nil {
		fatal("Load config: %v", err)
	}

	if service.IsRunning(cfg.ControlPort) {
		fatal("Proxy is already running (control port %d is active)", cfg.ControlPort)
	}

	withDashboard := hasFlag("--dashboard") || hasFlag("-d")
	if withDashboard {
		cfg.DashboardEnabled = true
	}

	daemon := service.NewDaemon(cfg, embedded.DefaultConfigJSON)
	if err := daemon.Start(); err != nil {
		fatal("Start daemon: %v", err)
	}

	fmt.Printf("Proxy started on 127.0.0.1:%d\n", cfg.ProxyPort)
	fmt.Printf("Control API on 127.0.0.1:%d\n", cfg.ControlPort)
	if cfg.DashboardEnabled {
		fmt.Printf("Dashboard on http://127.0.0.1:%d\n", cfg.DashboardPort)
	}
	fmt.Println("\nPress Ctrl+C to stop.")

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig

	fmt.Println("\nStopping...")
	daemon.Stop()
}

func cmdStop() {
	cfg := loadConfigOrDefault()
	if !service.IsRunning(cfg.ControlPort) {
		fmt.Println("Proxy is not running.")
		return
	}
	_, err := service.SendCommand(cfg.ControlPort, "/stop")
	if err != nil {
		fmt.Println("Stopped.")
		return
	}
	fmt.Println("Stop signal sent.")
}

func cmdStatus() {
	cfg := loadConfigOrDefault()
	if !service.IsRunning(cfg.ControlPort) {
		fmt.Println("Status: stopped")
		return
	}
	data, err := service.SendCommand(cfg.ControlPort, "/status")
	if err != nil {
		fatal("Cannot reach daemon: %v", err)
	}
	var status service.StatusResponse
	json.Unmarshal(data, &status)

	fmt.Printf("Status:      running\n")
	fmt.Printf("Uptime:      %s\n", status.Uptime)
	fmt.Printf("Proxy:       %s\n", status.ProxyAddr)
	fmt.Printf("Dashboard:   %v", status.DashboardEnabled)
	if status.DashboardAddr != "" {
		fmt.Printf(" (%s)", status.DashboardAddr)
	}
	fmt.Println()
	fmt.Printf("Requests:    %d total, %d proxied, %d direct\n",
		status.TotalRequests, status.ProxiedRequests, status.DirectRequests)
	fmt.Printf("Active:      %d connections\n", status.ActiveConns)
}

func cmdReload() {
	cfg := loadConfigOrDefault()
	if !service.IsRunning(cfg.ControlPort) {
		fatal("Proxy is not running")
	}
	_, err := service.SendCommand(cfg.ControlPort, "/reload")
	if err != nil {
		fatal("Reload failed: %v", err)
	}
	fmt.Println("Configuration reloaded.")
}

func cmdConfig() {
	if len(os.Args) < 3 {
		fmt.Println("Usage: proxy config <show|set|reset>")
		return
	}
	switch os.Args[2] {
	case "show":
		cfg := loadConfigOrDefault()
		data, _ := json.MarshalIndent(cfg, "", "  ")
		fmt.Println(string(data))
	case "set":
		if len(os.Args) < 5 {
			fmt.Println("Usage: proxy config set <key> <value>")
			return
		}
		cfg := loadConfigOrDefault()
		key, val := os.Args[3], os.Args[4]
		switch key {
		case "proxy_port":
			v, _ := strconv.Atoi(val)
			cfg.ProxyPort = v
		case "control_port":
			v, _ := strconv.Atoi(val)
			cfg.ControlPort = v
		case "dashboard_port":
			v, _ := strconv.Atoi(val)
			cfg.DashboardPort = v
		case "ssid_pattern":
			cfg.SSIDPattern = val
		case "auto_switch":
			cfg.AutoSwitch = val == "true"
		case "dashboard_enabled":
			cfg.DashboardEnabled = val == "true"
		default:
			fatal("Unknown config key: %s\nValid keys: proxy_port, control_port, dashboard_port, ssid_pattern, auto_switch, dashboard_enabled", key)
		}
		config.Save(cfg)
		fmt.Printf("Set %s = %s\n", key, val)
	case "reset":
		exePath, _ := os.Executable()
		cfgPath := filepath.Join(filepath.Dir(exePath), "config.json")
		os.WriteFile(cfgPath, embedded.DefaultConfigJSON, 0644)
		fmt.Println("Configuration reset to defaults.")
	default:
		fmt.Println("Usage: proxy config <show|set|reset>")
	}
}

func cmdDomains() {
	if len(os.Args) < 3 {
		fmt.Println("Usage: proxy domains <list|add|remove>")
		return
	}
	switch os.Args[2] {
	case "list":
		cfg := loadConfigOrDefault()
		total := 0
		for group, domains := range cfg.Domains {
			fmt.Printf("\n[%s] (%d)\n", group, len(domains))
			for _, d := range domains {
				fmt.Printf("  %s\n", d)
			}
			total += len(domains)
		}
		fmt.Printf("\nTotal: %d domains in %d groups\n", total, len(cfg.Domains))
	case "add":
		if len(os.Args) < 5 {
			fmt.Println("Usage: proxy domains add <group> <domain>")
			return
		}
		group, domain := os.Args[3], os.Args[4]
		cfg := loadConfigOrDefault()
		cfg.Domains[group] = append(cfg.Domains[group], domain)
		config.Save(cfg)
		fmt.Printf("Added %s to group [%s]\n", domain, group)
		reloadIfRunning(cfg)
	case "remove":
		if len(os.Args) < 4 {
			fmt.Println("Usage: proxy domains remove <domain>")
			return
		}
		domain := os.Args[3]
		cfg := loadConfigOrDefault()
		found := false
		for g, domains := range cfg.Domains {
			filtered := domains[:0]
			for _, d := range domains {
				if d == domain {
					found = true
				} else {
					filtered = append(filtered, d)
				}
			}
			cfg.Domains[g] = filtered
		}
		if !found {
			fmt.Printf("Domain %s not found in any group\n", domain)
			return
		}
		config.Save(cfg)
		fmt.Printf("Removed %s\n", domain)
		reloadIfRunning(cfg)
	default:
		fmt.Println("Usage: proxy domains <list|add|remove>")
	}
}

func cmdDashboard() {
	if len(os.Args) < 3 {
		fmt.Println("Usage: proxy dashboard <on|off>")
		return
	}
	cfg := loadConfigOrDefault()
	if !service.IsRunning(cfg.ControlPort) {
		fatal("Proxy is not running. Start it first with: proxy start")
	}
	switch os.Args[2] {
	case "on":
		service.SendCommand(cfg.ControlPort, "/dashboard/on")
		fmt.Printf("Dashboard activated: http://127.0.0.1:%d\n", cfg.DashboardPort)
	case "off":
		service.SendCommand(cfg.ControlPort, "/dashboard/off")
		fmt.Println("Dashboard deactivated.")
	default:
		fmt.Println("Usage: proxy dashboard <on|off>")
	}
}

func cmdInstall() {
	if runtime.GOOS != "windows" {
		fatal("Install is only supported on Windows")
	}

	mode := "--cli"
	if hasFlag("--full") {
		mode = "--full"
	}

	exePath, _ := os.Executable()
	installDir := filepath.Join(os.Getenv("USERPROFILE"), ".proxy")
	os.MkdirAll(installDir, 0755)

	destExe := filepath.Join(installDir, "proxy.exe")
	input, err := os.ReadFile(exePath)
	if err != nil {
		fatal("Read exe: %v", err)
	}
	os.WriteFile(destExe, input, 0755)

	startArgs := "start"
	if mode == "--full" {
		startArgs = "start --dashboard"
	}

	// Register scheduled task
	taskXML := fmt.Sprintf(`schtasks /create /tn "CompanyProxyAuto" /tr "\"%s\" %s" /sc onlogon /rl limited /f`, destExe, startArgs)
	cmd := exec.Command("cmd", "/C", taskXML)
	cmd.Run()

	// Set environment variables
	setUserEnv("HTTP_PROXY", fmt.Sprintf("http://127.0.0.1:%d", 8081))
	setUserEnv("HTTPS_PROXY", fmt.Sprintf("http://127.0.0.1:%d", 8081))

	fmt.Println("Installation complete!")
	fmt.Printf("  Executable: %s\n", destExe)
	fmt.Printf("  Mode: %s\n", mode)
	fmt.Printf("  HTTP_PROXY/HTTPS_PROXY → http://127.0.0.1:8081\n")
	fmt.Println("\n  Proxy will start automatically on login.")
	fmt.Println("  Restart your terminal for env vars to take effect.")
}

func cmdUninstall() {
	if runtime.GOOS != "windows" {
		fatal("Uninstall is only supported on Windows")
	}

	cfg := loadConfigOrDefault()
	if service.IsRunning(cfg.ControlPort) {
		service.SendCommand(cfg.ControlPort, "/stop")
	}

	exec.Command("cmd", "/C", `schtasks /delete /tn "CompanyProxyAuto" /f`).Run()

	removeUserEnv("HTTP_PROXY")
	removeUserEnv("HTTPS_PROXY")

	fmt.Println("Uninstalled.")
	fmt.Println("  Removed scheduled task")
	fmt.Println("  Cleared HTTP_PROXY/HTTPS_PROXY")
	fmt.Printf("  Config preserved at: %s\n", config.ConfigPath())
}

func loadConfigOrDefault() *config.Config {
	cfg, err := config.Load(embedded.DefaultConfigJSON)
	if err != nil {
		return config.DefaultConfig()
	}
	return cfg
}

func reloadIfRunning(cfg *config.Config) {
	if service.IsRunning(cfg.ControlPort) {
		service.SendCommand(cfg.ControlPort, "/reload")
		fmt.Println("(live reload applied)")
	}
}

func hasFlag(flag string) bool {
	for _, a := range os.Args[2:] {
		if a == flag {
			return true
		}
	}
	return false
}

func setUserEnv(name, value string) {
	exec.Command("cmd", "/C", fmt.Sprintf(`setx %s "%s"`, name, value)).Run()
}

func removeUserEnv(name string) {
	exec.Command("cmd", "/C", fmt.Sprintf(`reg delete "HKCU\Environment" /v %s /f`, name)).Run()
}

func fatal(format string, args ...interface{}) {
	fmt.Fprintf(os.Stderr, "Error: "+format+"\n", args...)
	os.Exit(1)
}
