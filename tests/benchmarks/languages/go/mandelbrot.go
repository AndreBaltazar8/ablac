package main

import (
	"os"
	"strconv"
)

func main() {
	n, e := strconv.Atoi(os.Args[1])
	if e != nil {
		panic(e)
	}
	mandelbrot(n)
}
