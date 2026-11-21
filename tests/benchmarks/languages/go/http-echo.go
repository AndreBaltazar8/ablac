package main

import (
	"bytes"
	"net"
	"os"
)

func main() {
	ln, e := net.Listen("tcp4", "127.0.0.1:"+os.Args[1])
	if e != nil {
		panic(e)
	}
	for {
		c, e := ln.Accept()
		if e != nil {
			panic(e)
		}
		buf := make([]byte, 8192)
		n := 0
		for {
			r, e := c.Read(buf[n:])
			if r == 0 || e != nil {
				break
			}
			n += r
			at := bytes.Index(buf[:n], []byte("\r\n\r\n"))
			if at >= 0 && n >= at+4+256 {
				response := append([]byte("HTTP/1.1 200 OK\r\nContent-Length: 256\r\nConnection: close\r\n\r\n"), buf[at+4:at+4+256]...)
				for len(response) > 0 {
					r, e = c.Write(response)
					if e != nil || r == 0 {
						break
					}
					response = response[r:]
				}
				break
			}
			if n == len(buf) {
				break
			}
		}
		c.Close()
	}
}
