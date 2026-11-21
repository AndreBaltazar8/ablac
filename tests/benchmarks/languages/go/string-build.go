package main

import (
	"os"
	"strconv"
	"strings"
)

func main() {
	count, err := strconv.Atoi(os.Args[1])
	if err != nil {
		os.Exit(2)
	}
	var text strings.Builder
	for i := 0; i < count; i++ {
		chunk := "alpha: 01234567\n"
		if i%2 != 0 {
			chunk = "bravo: 76543210\n"
		}
		text.WriteString(chunk)
	}
	if _, err := os.Stdout.WriteString(text.String()); err != nil {
		os.Exit(1)
	}
}
