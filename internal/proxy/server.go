package proxy

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"sync/atomic"
	"time"

	"company-proxy-auto/internal/matcher"
)

type Stats struct {
	TotalRequests   atomic.Int64
	ProxiedRequests atomic.Int64
	DirectRequests  atomic.Int64
	ActiveConns     atomic.Int64
	StartTime       time.Time
}

type LogEntry struct {
	Time   time.Time `json:"time"`
	Method string    `json:"method"`
	Host   string    `json:"host"`
	Proxied bool    `json:"proxied"`
	Status int      `json:"status"`
}

type Server struct {
	listenAddr    string
	upstreamProxy string
	matcher       *matcher.Matcher
	Stats         *Stats
	logBuf        []LogEntry
	logPos        int
	logMax        int
	httpServer    *http.Server
}

func New(listenAddr, upstreamProxy string, m *matcher.Matcher, logMax int) *Server {
	s := &Server{
		listenAddr:    listenAddr,
		upstreamProxy: upstreamProxy,
		matcher:       m,
		Stats:         &Stats{StartTime: time.Now()},
		logBuf:        make([]LogEntry, logMax),
		logMax:        logMax,
	}
	s.httpServer = &http.Server{
		Addr:    listenAddr,
		Handler: s,
	}
	return s
}

func (s *Server) Start() error {
	ln, err := net.Listen("tcp", s.listenAddr)
	if err != nil {
		return fmt.Errorf("listen %s: %w", s.listenAddr, err)
	}
	go s.httpServer.Serve(ln)
	return nil
}

func (s *Server) Stop() error {
	return s.httpServer.Close()
}

func (s *Server) Addr() string {
	return s.listenAddr
}

func (s *Server) RecentLogs(n int) []LogEntry {
	if n > s.logMax {
		n = s.logMax
	}
	total := int(s.Stats.TotalRequests.Load())
	if total < n {
		n = total
	}
	logs := make([]LogEntry, 0, n)
	start := (s.logPos - n + s.logMax) % s.logMax
	for i := 0; i < n; i++ {
		idx := (start + i) % s.logMax
		logs = append(logs, s.logBuf[idx])
	}
	return logs
}

func (s *Server) addLog(entry LogEntry) {
	s.logBuf[s.logPos%s.logMax] = entry
	s.logPos++
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.Stats.TotalRequests.Add(1)
	s.Stats.ActiveConns.Add(1)
	defer s.Stats.ActiveConns.Add(-1)

	if r.Method == http.MethodConnect {
		s.handleConnect(w, r)
	} else {
		s.handleHTTP(w, r)
	}
}

func (s *Server) handleConnect(w http.ResponseWriter, r *http.Request) {
	host := r.Host
	proxied := s.matcher.ShouldProxy(host)

	var targetConn net.Conn
	var err error

	if proxied {
		s.Stats.ProxiedRequests.Add(1)
		targetConn, err = s.connectViaProxy(host)
	} else {
		s.Stats.DirectRequests.Add(1)
		targetConn, err = net.DialTimeout("tcp", host, 10*time.Second)
	}

	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		s.addLog(LogEntry{Time: time.Now(), Method: "CONNECT", Host: host, Proxied: proxied, Status: 502})
		return
	}
	defer targetConn.Close()

	hj, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "hijack not supported", http.StatusInternalServerError)
		return
	}

	clientConn, _, err := hj.Hijack()
	if err != nil {
		return
	}
	defer clientConn.Close()

	clientConn.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n"))

	s.addLog(LogEntry{Time: time.Now(), Method: "CONNECT", Host: host, Proxied: proxied, Status: 200})

	go io.Copy(targetConn, clientConn)
	io.Copy(clientConn, targetConn)
}

func (s *Server) handleHTTP(w http.ResponseWriter, r *http.Request) {
	host := r.Host
	if host == "" {
		host = r.URL.Host
	}
	proxied := s.matcher.ShouldProxy(host)

	var transport *http.Transport
	if proxied {
		s.Stats.ProxiedRequests.Add(1)
		proxyURL, _ := url.Parse(s.upstreamProxy)
		transport = &http.Transport{Proxy: http.ProxyURL(proxyURL)}
	} else {
		s.Stats.DirectRequests.Add(1)
		transport = &http.Transport{}
	}

	outReq, err := http.NewRequestWithContext(r.Context(), r.Method, r.URL.String(), r.Body)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	outReq.Header = r.Header.Clone()
	outReq.Header.Del("Proxy-Connection")

	resp, err := transport.RoundTrip(outReq)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		s.addLog(LogEntry{Time: time.Now(), Method: r.Method, Host: host, Proxied: proxied, Status: 502})
		return
	}
	defer resp.Body.Close()

	s.addLog(LogEntry{Time: time.Now(), Method: r.Method, Host: host, Proxied: proxied, Status: resp.StatusCode})

	for k, vv := range resp.Header {
		for _, v := range vv {
			w.Header().Add(k, v)
		}
	}
	w.WriteHeader(resp.StatusCode)
	io.Copy(w, resp.Body)
}

func (s *Server) connectViaProxy(targetHost string) (net.Conn, error) {
	proxyURL, err := url.Parse(s.upstreamProxy)
	if err != nil {
		return nil, err
	}

	proxyAddr := proxyURL.Host
	if !hasPort(proxyAddr) {
		proxyAddr += ":8080"
	}

	conn, err := net.DialTimeout("tcp", proxyAddr, 10*time.Second)
	if err != nil {
		return nil, fmt.Errorf("dial proxy: %w", err)
	}

	fmt.Fprintf(conn, "CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", targetHost, targetHost)

	buf := make([]byte, 4096)
	n, err := conn.Read(buf)
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("proxy CONNECT response: %w", err)
	}

	response := string(buf[:n])
	if len(response) < 12 || response[9] != '2' {
		conn.Close()
		return nil, fmt.Errorf("proxy CONNECT rejected: %s", response[:min(len(response), 50)])
	}

	return conn, nil
}

func hasPort(host string) bool {
	_, _, err := net.SplitHostPort(host)
	return err == nil
}
