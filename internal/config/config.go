package config

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
)

type Config struct {
	ProxyPort       int                 `json:"proxy_port"`
	ControlPort     int                 `json:"control_port"`
	DashboardPort   int                 `json:"dashboard_port"`
	UpstreamProxies []string            `json:"upstream_proxies"`
	SSIDPattern     string              `json:"ssid_pattern"`
	AutoSwitch      bool                `json:"auto_switch"`
	DashboardEnabled bool              `json:"dashboard_enabled"`
	LogMaxEntries   int                 `json:"log_max_entries"`
	Domains         map[string][]string `json:"domains"`
}

var (
	current *Config
	mu      sync.RWMutex
	cfgPath string
)

func DefaultConfig() *Config {
	return &Config{
		ProxyPort:       8081,
		ControlPort:     8082,
		DashboardPort:   8083,
		UpstreamProxies: []string{"http://proxy.pvgl.sap.corp:8080"},
		SSIDPattern:     "SAP",
		AutoSwitch:      true,
		DashboardEnabled: false,
		LogMaxEntries:   100,
		Domains:         map[string][]string{},
	}
}

func ConfigPath() string {
	return cfgPath
}

func Load(defaultJSON []byte) (*Config, error) {
	exePath, err := os.Executable()
	if err != nil {
		return nil, fmt.Errorf("resolve executable path: %w", err)
	}
	cfgPath = filepath.Join(filepath.Dir(exePath), "config.json")

	data, err := os.ReadFile(cfgPath)
	if err != nil {
		if os.IsNotExist(err) {
			if err := os.WriteFile(cfgPath, defaultJSON, 0644); err != nil {
				return nil, fmt.Errorf("write default config: %w", err)
			}
			data = defaultJSON
		} else {
			return nil, fmt.Errorf("read config: %w", err)
		}
	}

	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}

	if cfg.LogMaxEntries <= 0 {
		cfg.LogMaxEntries = 100
	}

	mu.Lock()
	current = &cfg
	mu.Unlock()

	return &cfg, nil
}

func Get() *Config {
	mu.RLock()
	defer mu.RUnlock()
	return current
}

func Reload(defaultJSON []byte) (*Config, error) {
	return Load(defaultJSON)
}

func Save(cfg *Config) error {
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal config: %w", err)
	}
	if err := os.WriteFile(cfgPath, data, 0644); err != nil {
		return fmt.Errorf("write config: %w", err)
	}
	mu.Lock()
	current = cfg
	mu.Unlock()
	return nil
}

func AllDomains(cfg *Config) []string {
	var all []string
	for _, domains := range cfg.Domains {
		all = append(all, domains...)
	}
	return all
}
