package main

import (
	"crypto/tls"
	"net"
	"strconv"
	"time"
)

// client PORT COUNT: connects COUNT times to 127.0.0.1:PORT (tools/tls-diff/hello-server.ab) with crypto/tls (no certificate checks: the handshake
// never gets that far), a short deadline each; the server reads off the wire what Go does.
func client(port string, rest []string) {
	count := 1
	if len(rest) > 0 {
		count, _ = strconv.Atoi(rest[0])
	}
	config := &tls.Config{InsecureSkipVerify: true, MinVersion: tls.VersionTLS12}
	for i := 0; i < count; i++ {
		connection, err := net.DialTimeout("tcp", "127.0.0.1:"+port, 2*time.Second)
		if err != nil {
			continue
		}
		connection.SetDeadline(time.Now().Add(450 * time.Millisecond))
		secured := tls.Client(connection, config)
		secured.Handshake()
		connection.Close()
	}
}

// flight PORT COUNT: as client, for tools/tls-diff/flight-server.ab, which does a real handshake: the certificate is not checked (it is the server's own), the
// signature and the Finished are; after a handshake that succeeds it reads for a short while, so the post-handshake messages are processed.
func flightClient(port string, rest []string, version uint16) {
	count := 1
	if len(rest) > 0 {
		count, _ = strconv.Atoi(rest[0])
	}
	config := &tls.Config{InsecureSkipVerify: true, MinVersion: version, MaxVersion: version}
	for i := 0; i < count; i++ {
		connection, err := net.DialTimeout("tcp", "127.0.0.1:"+port, 2*time.Second)
		if err != nil {
			continue
		}
		connection.SetDeadline(time.Now().Add(900 * time.Millisecond))
		secured := tls.Client(connection, config)
		if secured.Handshake() == nil {
			connection.SetReadDeadline(time.Now().Add(300 * time.Millisecond))
			buffer := make([]byte, 64)
			secured.Read(buffer)
		}
		connection.Close()
	}
}
