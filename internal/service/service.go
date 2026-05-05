package service

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"company-proxy-auto/internal/config"
	"company-proxy-auto/internal/dashboard"
	"company-proxy-auto/internal/matcher"
	"company-proxy-auto/internal/proxy"
)

type Daemon struct {
	cfg            *config.Config
	defaultJSON    []byte
	proxyServer    *proxy.Server
	controlServer  *http.Server
	dashboardSrv   *dashboard.Server
	matcher        *matcher.Matcher
	pidFile        string
}

type StatusResponse struct {
	Running          bool    `json:"running"`
	Uptime           string  `json:"uptime"`
	ProxyAddr        string  `json:"proxy_addr"`
	DashboardEnabled bool    `json:"dashboard_enabled"`
	DashboardAddr    string  `json:"dashboard_addr,omitempty"`
	TotalRequests    int64   `json:"total_requests"`
	ProxiedRequests  int64   `json:"proxied_requests"`
	DirectRequests   int64   `json:"direct_requests"`
	ActiveConns      int64   `json:"active_conns"`
}

func NewDaemon(cfg *config.Config, defaultJSON []byte) *Daemon {
	exePath, _ := os.Executable()
	pidFile := filepath.Join(filepath.Dir(exePath), "proxy.pid")

	return &Daemon{
		cfg:         cfg,
		defaultJSON: defaultJSON,
		pidFile:     pidFile,
	}
}

func (d *Daemon) Start() error {
	if err := d.writePID(); err != nil {
		return err
	}

	allDomains := config.AllDomains(d.cfg)
	d.matcher = matcher.New(allDomains)

	upstream := ""
	if len(d.cfg.UpstreamProxies) > 0 {
		upstream = d.cfg.UpstreamProxies[0]
	}

	listenAddr := fmt.Sprintf("127.0.0.1:%d", d.cfg.ProxyPort)
	d.proxyServer = proxy.New(listenAddr, upstream, d.matcher, d.cfg.LogMaxEntries)
	if err := d.proxyServer.Start(); err != nil {
		return err
	}

	if err := d.startControl(); err != nil {
		return err
	}

	if d.cfg.DashboardEnabled {
		d.startDashboard()
	}

	return nil
}

func (d *Daemon) Stop() {
	if d.proxyServer != nil {
		d.proxyServer.Stop()
	}
	if d.controlServer != nil {
		d.controlServer.Close()
	}
	if d.dashboardSrv != nil {
		d.dashboardSrv.Stop()
	}
	os.Remove(d.pidFile)
}

func (d *Daemon) startControl() error {
	mux := http.NewServeMux()
	mux.HandleFunc("/status", d.handleStatus)
	mux.HandleFunc("/stop", d.handleStop)
	mux.HandleFunc("/reload", d.handleReload)
	mux.HandleFunc("/dashboard/on", d.handleDashboardOn)
	mux.HandleFunc("/dashboard/off", d.handleDashboardOff)
	mux.HandleFunc("/domains", d.handleDomains)
	mux.HandleFunc("/domains/add", d.handleDomainsAdd)
	mux.HandleFunc("/domains/remove", d.handleDomainsRemove)
	mux.HandleFunc("/config", d.handleConfig)
	mux.HandleFunc("/logs", d.handleLogs)

	addr := fmt.Sprintf("127.0.0.1:%d", d.cfg.ControlPort)
	d.controlServer = &http.Server{Addr: addr, Handler: mux}

	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("control listen %s: %w", addr, err)
	}
	go d.controlServer.Serve(ln)
	return nil
}

func (d *Daemon) startDashboard() {
	addr := fmt.Sprintf("127.0.0.1:%d", d.cfg.DashboardPort)
	d.dashboardSrv = dashboard.New(addr, d.proxyServer)
	d.dashboardSrv.Start()
}

func (d *Daemon) handleStatus(w http.ResponseWriter, r *http.Request) {
	stats := d.proxyServer.Stats
	status := StatusResponse{
		Running:          true,
		Uptime:           time.Since(stats.StartTime).Truncate(time.Second).String(),
		ProxyAddr:        d.proxyServer.Addr(),
		DashboardEnabled: d.dashboardSrv != nil,
		TotalRequests:    stats.TotalRequests.Load(),
		ProxiedRequests:  stats.ProxiedRequests.Load(),
		DirectRequests:   stats.DirectRequests.Load(),
		ActiveConns:      stats.ActiveConns.Load(),
	}
	if d.dashboardSrv != nil {
		status.DashboardAddr = fmt.Sprintf("http://127.0.0.1:%d", d.cfg.DashboardPort)
	}
	json.NewEncoder(w).Encode(status)
}

func (d *Daemon) handleStop(w http.ResponseWriter, r *http.Request) {
	w.Write([]byte(`{"ok":true}`))
	go func() {
		time.Sleep(100 * time.Millisecond)
		d.Stop()
		os.Exit(0)
	}()
}

func (d *Daemon) handleReload(w http.ResponseWriter, r *http.Request) {
	cfg, err := config.Reload(d.defaultJSON)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	d.cfg = cfg
	d.matcher.Update(config.AllDomains(cfg))
	w.Write([]byte(`{"ok":true}`))
}

func (d *Daemon) handleDashboardOn(w http.ResponseWriter, r *http.Request) {
	if d.dashboardSrv != nil {
		w.Write([]byte(`{"ok":true,"msg":"already running"}`))
		return
	}
	d.startDashboard()
	d.cfg.DashboardEnabled = true
	config.Save(d.cfg)
	w.Write([]byte(`{"ok":true}`))
}

func (d *Daemon) handleDashboardOff(w http.ResponseWriter, r *http.Request) {
	if d.dashboardSrv == nil {
		w.Write([]byte(`{"ok":true,"msg":"not running"}`))
		return
	}
	d.dashboardSrv.Stop()
	d.dashboardSrv = nil
	d.cfg.DashboardEnabled = false
	config.Save(d.cfg)
	w.Write([]byte(`{"ok":true}`))
}

func (d *Daemon) handleDomains(w http.ResponseWriter, r *http.Request) {
	json.NewEncoder(w).Encode(d.cfg.Domains)
}

func (d *Daemon) handleDomainsAdd(w http.ResponseWriter, r *http.Request) {
	group := r.URL.Query().Get("group")
	domain := r.URL.Query().Get("domain")
	if group == "" || domain == "" {
		http.Error(w, "group and domain required", http.StatusBadRequest)
		return
	}
	if d.cfg.Domains == nil {
		d.cfg.Domains = make(map[string][]string)
	}
	d.cfg.Domains[group] = append(d.cfg.Domains[group], domain)
	d.matcher.Update(config.AllDomains(d.cfg))
	config.Save(d.cfg)
	w.Write([]byte(`{"ok":true}`))
}

func (d *Daemon) handleDomainsRemove(w http.ResponseWriter, r *http.Request) {
	group := r.URL.Query().Get("group")
	domain := r.URL.Query().Get("domain")
	if domain == "" {
		http.Error(w, "domain required", http.StatusBadRequest)
		return
	}

	for g, domains := range d.cfg.Domains {
		if group != "" && g != group {
			continue
		}
		filtered := domains[:0]
		for _, dom := range domains {
			if dom != domain {
				filtered = append(filtered, dom)
			}
		}
		d.cfg.Domains[g] = filtered
	}
	d.matcher.Update(config.AllDomains(d.cfg))
	config.Save(d.cfg)
	w.Write([]byte(`{"ok":true}`))
}

func (d *Daemon) handleConfig(w http.ResponseWriter, r *http.Request) {
	json.NewEncoder(w).Encode(d.cfg)
}

func (d *Daemon) handleLogs(w http.ResponseWriter, r *http.Request) {
	n := 50
	if q := r.URL.Query().Get("n"); q != "" {
		if v, err := strconv.Atoi(q); err == nil && v > 0 {
			n = v
		}
	}
	logs := d.proxyServer.RecentLogs(n)
	json.NewEncoder(w).Encode(logs)
}

func (d *Daemon) writePID() error {
	return os.WriteFile(d.pidFile, []byte(strconv.Itoa(os.Getpid())), 0644)
}

func IsRunning(controlPort int) bool {
	conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", controlPort), 500*time.Millisecond)
	if err != nil {
		return false
	}
	conn.Close()
	return true
}

func SendCommand(controlPort int, path string) ([]byte, error) {
	addr := fmt.Sprintf("http://127.0.0.1:%d%s", controlPort, path)
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(addr)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	return io.ReadAll(resp.Body)
}
