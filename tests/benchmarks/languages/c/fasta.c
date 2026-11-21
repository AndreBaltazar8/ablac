#include "cpu.h"
int main(int argc, char **argv) {
  fasta(argc > 1 ? atoi(argv[1]) : 10);
  return 0;
}
