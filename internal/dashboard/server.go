package dashboard

import (
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"net"
	"net/http"

	"company-proxy-auto/internal/proxy"
)

//go:embed static
var staticFS embed.FS

type Server struct {
	addr       string
	httpServer *http.Server
	proxy      *proxy.Server
}

func New(addr string, proxyServer *proxy.Server) *Server {
	s := &Server{addr: addr, proxy: proxyServer}

	mux := http.NewServeMux()

	staticContent, _ := fs.Sub(staticFS, "static")
	mux.Handle("/", http.FileServer(http.FS(staticContent)))

	mux.HandleFunc("/api/stats", s.handleStats)
	mux.HandleFunc("/api/logs", s.handleLogs)

	s.httpServer = &http.Server{Addr: addr, Handler: mux}
	return s
}

func (s *Server) Start() error {
	ln, err := net.Listen("tcp", s.addr)
	if err != nil {
		return fmt.Errorf("dashboard listen %s: %w", s.addr, err)
	}
	go s.httpServer.Serve(ln)
	return nil
}

func (s *Server) Stop() {
	if s.httpServer != nil {
		s.httpServer.Close()
	}
}

func (s *Server) handleStats(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	stats := s.proxy.Stats
	json.NewEncoder(w).Encode(map[string]interface{}{
		"uptime":           stats.StartTime,
		"total_requests":   stats.TotalRequests.Load(),
		"proxied_requests": stats.ProxiedRequests.Load(),
		"direct_requests":  stats.DirectRequests.Load(),
		"active_conns":     stats.ActiveConns.Load(),
	})
}

func (s *Server) handleLogs(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	logs := s.proxy.RecentLogs(50)
	json.NewEncoder(w).Encode(logs)
}
