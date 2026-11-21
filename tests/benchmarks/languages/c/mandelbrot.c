#include "cpu.h"
int main(int argc, char **argv) {
  mandelbrot(argc > 1 ? atoi(argv[1]) : 10);
  return 0;
}
