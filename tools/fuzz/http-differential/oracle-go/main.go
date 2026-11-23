// The reference verdicts of Go's net/http request reader for the streams of gen.mjs, in the format of oracle-llhttp.mjs:
//   go run ./oracle-go cases.tsv > go.tsv
package main

import (
	"bufio"
	"bytes"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
)

func main() {
	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	for _, line := range strings.Split(string(data), "\n") {
		if line == "" {
			continue
		}
		fields := strings.Split(line, "\t")
		stream, _ := hex.DecodeString(fields[2])
		reader := bufio.NewReader(bytes.NewReader(stream))
		var verdict []string
		for {
			request, err := http.ReadRequest(reader)
			if err != nil {
				if err == io.EOF {
					break
				}
				if err == io.ErrUnexpectedEOF {
					break
				}
				verdict = append(verdict, "E:"+strings.ReplaceAll(err.Error(), " ", "_"))
				break
			}
			body, berr := io.ReadAll(request.Body)
			if berr != nil {
				verdict = append(verdict, "E:body_"+strings.ReplaceAll(berr.Error(), " ", "_"))
				break
			}
			path := request.RequestURI
			if i := strings.IndexByte(path, '?'); i >= 0 {
				path = path[:i]
			}
			b := hex.EncodeToString(body)
			if b == "" {
				b = "-"
			}
			verdict = append(verdict, fmt.Sprintf("R:%s %s %s", request.Method, path, b))
			if request.Close || (request.ProtoMajor == 1 && request.ProtoMinor == 0 && !strings.Contains(strings.ToLower(request.Header.Get("Connection")), "keep-alive")) {
				break
			}
		}
		if len(verdict) == 0 {
			fmt.Printf("%s\tI\n", fields[0])
		} else {
			fmt.Printf("%s\t%s\n", fields[0], strings.Join(verdict, " | "))
		}
	}
}
