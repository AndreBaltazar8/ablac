package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strconv"
)

func main() {
	n, e := strconv.Atoi(os.Args[1])
	if e != nil {
		panic(e)
	}
	s, e := os.ReadFile(os.Args[2])
	if e != nil {
		panic(e)
	}
	for i := 0; i < n; i++ {
		var v any
		if e = json.Unmarshal(s, &v); e != nil {
			panic(e)
		}
		out, e := json.Marshal(v)
		if e != nil {
			panic(e)
		}
		if i == n-1 {
			fmt.Println(string(out))
		}
	}
}
