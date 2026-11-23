// The Go side of the TLS handshake differential (tools/tls-diff, #1139 area 3): crypto/tls as a peer for the hostile hellos the Abla harness sends.
//
//	peer server PORT CERT KEY   listens on 127.0.0.1:PORT, one connection at a time, a short deadline for its handshake, no output
//	peer client PORT [HOST]     (see client.go) connects to 127.0.0.1:PORT, to hostile ServerHellos, and exits with the way it ended
package main

import (
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"net"
	"os"
	"time"
)

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: peer server PORT CERT KEY | peer client PORT [HOST]")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "server":
		server(os.Args[2], os.Args[3], os.Args[4], len(os.Args) > 5 && os.Args[5] == "hold", clientCAArgument())
	case "client":
		client(os.Args[2], os.Args[3:])
	case "flight":
		flightClient(os.Args[2], os.Args[3:], tls.VersionTLS13)
	case "flight12":
		flightClient(os.Args[2], os.Args[3:], tls.VersionTLS12)
	default:
		os.Exit(2)
	}
}

func server(port, certFile, keyFile string, hold bool, clientCA string) {
	certificate, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		fmt.Fprintln(os.Stderr, "peer:", err)
		os.Exit(2)
	}
	config := &tls.Config{Certificates: []tls.Certificate{certificate}, MinVersion: tls.VersionTLS12}
	if clientCA != "" {
		pem, err := os.ReadFile(clientCA)
		if err != nil {
			fmt.Fprintln(os.Stderr, "peer:", err)
			os.Exit(2)
		}
		pool := x509.NewCertPool()
		pool.AppendCertsFromPEM(pem)
		config.ClientCAs = pool
		config.ClientAuth = tls.RequireAndVerifyClientCert
	}
	listener, err := net.Listen("tcp", "127.0.0.1:"+port)
	if err != nil {
		fmt.Fprintln(os.Stderr, "peer:", err)
		os.Exit(2)
	}
	fmt.Println("listening", port)
	for {
		connection, err := listener.Accept()
		if err != nil {
			continue
		}
		connection.SetDeadline(time.Now().Add(400 * time.Millisecond))
		secured := tls.Server(connection, config)
		if secured.Handshake() == nil && hold {
			connection.SetDeadline(time.Now().Add(900 * time.Millisecond))
			buffer := make([]byte, 64)
			for {
				if _, err := secured.Read(buffer); err != nil {
					break
				}
			}
		}
		connection.Close()
	}
}

// The client CA file of `peer server PORT CERT KEY hold CLIENT_CA`: clients must present a certificate it issued.
func clientCAArgument() string {
	if len(os.Args) > 6 {
		return os.Args[6]
	}
	return ""
}
