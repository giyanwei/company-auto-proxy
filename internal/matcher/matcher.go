package matcher

import (
	"strings"
	"sync"
)

type Matcher struct {
	mu      sync.RWMutex
	domains map[string]bool
}

func New(domains []string) *Matcher {
	m := &Matcher{domains: make(map[string]bool, len(domains))}
	for _, d := range domains {
		m.domains[strings.ToLower(d)] = true
	}
	return m
}

func (m *Matcher) Update(domains []string) {
	newMap := make(map[string]bool, len(domains))
	for _, d := range domains {
		newMap[strings.ToLower(d)] = true
	}
	m.mu.Lock()
	m.domains = newMap
	m.mu.Unlock()
}

func (m *Matcher) ShouldProxy(host string) bool {
	host = strings.ToLower(host)
	if h, _, ok := strings.Cut(host, ":"); ok {
		host = h
	}

	if host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" {
		return false
	}

	m.mu.RLock()
	defer m.mu.RUnlock()

	if m.domains[host] {
		return true
	}

	for d := range m.domains {
		if strings.HasSuffix(host, "."+d) {
			return true
		}
	}
	return false
}
