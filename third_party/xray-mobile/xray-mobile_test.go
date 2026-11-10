package XRay

import (
	"strings"
	"testing"
)

// The exact shape lib/src/xray_config.dart emits, with the placeholder port and
// credentials the tunnel provider fills at startup.
const dartConfig = `{
  "log": {"loglevel": "warning"},
  "stats": {},
  "policy": {"system": {"statsOutboundUplink": true, "statsOutboundDownlink": true}},
  "inbounds": [{
    "tag": "socks-in",
    "protocol": "socks",
    "listen": "127.0.0.1",
    "port": 10808,
    "settings": {"auth": "password", "accounts": [{"user": "u", "pass": "p"}], "udp": true},
    "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
  }],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {"vnext": [{
        "address": "supervpn-testnet-01.mysterium.network",
        "port": 443,
        "users": [{"id": "f7422437-7044-4599-8165-5f7ae7311fc4", "encryption": "none", "level": 0}]
      }]},
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {"serverName": "supervpn-testnet-01.mysterium.network", "allowInsecure": false},
        "wsSettings": {"path": "/vless", "host": "supervpn-testnet-01.mysterium.network"}
      }
    },
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block", "protocol": "blackhole"}
  ]
}`

// The trimmed distro must register every feature the Dart layer can emit.
// Failing here means distro.go is missing an import.
func TestStartsWithTheConfigDartProduces(t *testing.T) {
	SetMemoryLimit()
	if err := Start([]byte(dartConfig)); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer Stop()

	if !IsRunning() {
		t.Fatal("expected IsRunning after a successful Start")
	}
}

func TestRejectsMalformedConfig(t *testing.T) {
	if err := Start([]byte("{not json")); err == nil {
		Stop()
		t.Fatal("expected an error for malformed config")
	}
}

// `infra/conf` ships config parsers for every protocol regardless of what
// distro.go registers, so a trimmed-out protocol like vmess still LOADS here —
// it only fails later, at handler construction. A genuinely unknown id is the
// one thing the config layer rejects outright.
//
// The practical consequence: Xray will not catch an unsupported protocol or
// transport for us. VlessUri.parse on the Dart side is the real guard.
func TestRejectsAnUnknownProtocolID(t *testing.T) {
	bogus := strings.Replace(dartConfig, `"protocol": "vless"`, `"protocol": "notarealprotocol"`, 1)
	err := Start([]byte(bogus))
	if err == nil {
		Stop()
		t.Fatal("expected an unknown protocol id to be refused")
	}
	if !strings.Contains(err.Error(), "unknown config id") {
		t.Fatalf("expected an unknown-config-id error, got: %v", err)
	}
}

func TestRefusesConcurrentStart(t *testing.T) {
	if err := Start([]byte(dartConfig)); err != nil {
		t.Fatalf("first Start: %v", err)
	}
	defer Stop()

	if err := Start([]byte(dartConfig)); err == nil {
		t.Fatal("expected the second Start to be refused")
	}
}

func TestGetVersionIsNotEmpty(t *testing.T) {
	if GetVersion() == "" {
		t.Fatal("expected a version string")
	}
}
