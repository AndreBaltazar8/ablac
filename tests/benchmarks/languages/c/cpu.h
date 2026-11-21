// Independently written scalar implementations of the Benchmarks Game tasks.
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef struct Tree {
  struct Tree *left, *right;
} Tree;
static Tree *tree_make(int d) {
  Tree *t = malloc(sizeof *t);
  t->left = d ? tree_make(d - 1) : NULL;
  t->right = d ? tree_make(d - 1) : NULL;
  return t;
}
static long tree_check(Tree *t) {
  return t->left ? 1 + tree_check(t->left) + tree_check(t->right) : 1;
}
static void tree_drop(Tree *t) {
  if (t->left) {
    tree_drop(t->left);
    tree_drop(t->right);
  }
  free(t);
}
static void binary_trees(int n) {
  Tree *stretch = tree_make(n + 1);
  printf("stretch %ld\n", tree_check(stretch));
  tree_drop(stretch);
  Tree *long_lived = tree_make(n);
  for (int d = 4; d <= n; d += 2) {
    long sum = 0;
    int rounds = 1 << (n - d + 4);
    for (int i = 0; i < rounds; i++) {
      Tree *t = tree_make(d);
      sum += tree_check(t);
      tree_drop(t);
    }
    printf("%d %d %ld\n", d, rounds, sum);
  }
  printf("long %ld\n", tree_check(long_lived));
  tree_drop(long_lived);
}
static void fannkuch(int n) {
  int p[16], q[16], count[16];
  for (int i = 0; i < n; i++)
    p[i] = i;
  int r = n, maximum = 0;
  long checksum = 0, idx = 0;
  for (;;) {
    while (r != 1) {
      count[r - 1] = r;
      r--;
    }
    memcpy(q, p, n * sizeof(int));
    int flips = 0;
    while (q[0]) {
      int k = q[0];
      for (int i = 0, j = k; i < j; i++, j--) {
        int t = q[i];
        q[i] = q[j];
        q[j] = t;
      }
      flips++;
    }
    if (flips > maximum)
      maximum = flips;
    checksum += (idx % 2 ? -flips : flips);
    idx++;
    for (;;) {
      if (r == n) {
        printf("%ld %d\n", checksum, maximum);
        return;
      }
      int first = p[0];
      for (int i = 0; i < r; i++)
        p[i] = p[i + 1];
      p[r] = first;
      count[r]--;
      if (count[r] > 0)
        break;
      r++;
    }
  }
}
static double matrix_a(int i, int j) {
  return 1.0 / ((i + j) * (i + j + 1) / 2 + i + 1);
}
static void multiply(double *u, double *v, int n, int transpose) {
  for (int i = 0; i < n; i++) {
    double s = 0;
    for (int j = 0; j < n; j++)
      s += (transpose ? matrix_a(j, i) : matrix_a(i, j)) * u[j];
    v[i] = s;
  }
}
static void spectral_norm(int n) {
  double *u = calloc(n, sizeof(double)), *v = calloc(n, sizeof(double)),
         *t = calloc(n, sizeof(double));
  for (int i = 0; i < n; i++)
    u[i] = 1;
  for (int i = 0; i < 10; i++) {
    multiply(u, t, n, 0);
    multiply(t, v, n, 1);
    multiply(v, t, n, 0);
    multiply(t, u, n, 1);
  }
  double uv = 0, vv = 0;
  for (int i = 0; i < n; i++) {
    uv += u[i] * v[i];
    vv += v[i] * v[i];
  }
  printf("%.9f\n", sqrt(uv / vv));
  free(u);
  free(v);
  free(t);
}
static void mandelbrot(int n) {
  printf("P4\n%d %d\n", n, n);
  for (int y = 0; y < n; y++) {
    int byte = 0, bits = 0;
    for (int x = 0; x < n; x++) {
      double cr = 2.0 * x / n - 1.5, ci = 2.0 * y / n - 1.0, zr = 0, zi = 0;
      int k = 0;
      while (k < 50 && zr * zr + zi * zi <= 4) {
        double next = zr * zr - zi * zi + cr;
        zi = 2 * zr * zi + ci;
        zr = next;
        k++;
      }
      byte = (byte << 1) | (zr * zr + zi * zi <= 4);
      bits++;
      if (bits == 8) {
        putchar(byte);
        byte = 0;
        bits = 0;
      }
    }
    if (bits)
      putchar(byte << (8 - bits));
  }
}
static unsigned seed = 42;
static const char alu[] =
    "GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGGGAGGCCGAGGCGGGCGGATCACCTGAGGTCAG"
    "GAGTTCGAGACCAGCCTGGCCAACATGGTGAAACCCCGTCTCTACTAAAAATACAAAAATTAGCCGGGCGTGGT"
    "GGCGCGCGCCTGTAATCCCAGCTACTCGGGAGGCTGAGGCAGGAGAATCGCTTGAACCCGGGAGGCGGAGGTTG"
    "CAGTGAGCCGAGATCGCGCCACTGCACTCCAGCCTGGGCGACAGAGCGAGACTCCGTCTCAAAAA";
static void fasta_random(int n, const char *letters, const double *prob,
                         int length) {
  for (int i = 0; i < n; i++) {
    seed = (seed * 3877 + 29573) % 139968;
    double r = (double)seed / 139968, c = 0;
    int j = 0;
    while (j < length - 1) {
      c += prob[j];
      if (r < c)
        break;
      j++;
    }
    putchar(letters[j]);
    if (i % 60 == 59 || i == n - 1)
      putchar('\n');
  }
}
static void fasta(int n) {
  puts(">ONE Homo sapiens alu");
  for (int i = 0; i < 2 * n; i++) {
    putchar(alu[i % (sizeof(alu) - 1)]);
    if (i % 60 == 59 || i == 2 * n - 1)
      putchar('\n');
  }
  puts(">TWO IUB ambiguity codes");
  double a[] = {.27, .12, .12, .27, .02, .02, .02, .02,
                .02, .02, .02, .02, .02, .02, .02};
  fasta_random(3 * n, "acgtBDHKMNRSVWY", a, 15);
  puts(">THREE Homo sapiens frequency");
  double b[] = {.3029549426680, .1979883004921, .1975473066391, .3015094502008};
  fasta_random(5 * n, "acgt", b, 4);
}
// Canonical solar-system initial conditions (units: AU, solar masses, years).
typedef struct {
  double x, y, z, vx, vy, vz, m;
} Body;
static Body bodies[] = {
    {0, 0, 0, 0, 0, 0, 39.47841760435743},
    {4.84143144246472090, -1.16032004402742839, -.103622044471123109,
     .00166007664274403694 * 365.24, .00769901118419740425 * 365.24,
     -.0000690460016972063023 * 365.24,
     .000954791938424326609 * 39.47841760435743},
    {8.34336671824457987, 4.12479856412430479, -.403523417114321381,
     -.00276742510726862411 * 365.24, .00499852801234917238 * 365.24,
     .0000230417297573763929 * 365.24,
     .000285885980666130812 * 39.47841760435743},
    {12.8943695621391310, -15.1111514016986312, -.223307578892655734,
     .00296460137564761618 * 365.24, .00237847173959480950 * 365.24,
     -.0000296589568540237556 * 365.24,
     .0000436624404335156298 * 39.47841760435743},
    {15.3796971148509165, -25.9193146099879641, .179258772950371181,
     .00268067772490389322 * 365.24, .00162824170038242295 * 365.24,
     -.0000951592254519715870 * 365.24,
     .0000515138902046611451 * 39.47841760435743}};
static double energy(void) {
  double e = 0;
  for (int i = 0; i < 5; i++) {
    Body *a = &bodies[i];
    e += .5 * a->m * (a->vx * a->vx + a->vy * a->vy + a->vz * a->vz);
    for (int j = i + 1; j < 5; j++) {
      Body *b = &bodies[j];
      double dx = a->x - b->x, dy = a->y - b->y, dz = a->z - b->z;
      e -= a->m * b->m / sqrt(dx * dx + dy * dy + dz * dz);
    }
  }
  return e;
}
static void n_body(int n) {
  for (int i = 0; i < 5; i++) {
    bodies[0].vx -= bodies[i].vx * bodies[i].m / 39.47841760435743;
    bodies[0].vy -= bodies[i].vy * bodies[i].m / 39.47841760435743;
    bodies[0].vz -= bodies[i].vz * bodies[i].m / 39.47841760435743;
  }
  printf("%.9f\n", energy());
  for (int s = 0; s < n; s++) {
    for (int i = 0; i < 5; i++)
      for (int j = i + 1; j < 5; j++) {
        Body *a = &bodies[i], *b = &bodies[j];
        double dx = a->x - b->x, dy = a->y - b->y, dz = a->z - b->z,
               d2 = dx * dx + dy * dy + dz * dz, mag = .01 / (d2 * sqrt(d2));
        a->vx -= dx * b->m * mag;
        a->vy -= dy * b->m * mag;
        a->vz -= dz * b->m * mag;
        b->vx += dx * a->m * mag;
        b->vy += dy * a->m * mag;
        b->vz += dz * a->m * mag;
      }
    for (int i = 0; i < 5; i++) {
      bodies[i].x += .01 * bodies[i].vx;
      bodies[i].y += .01 * bodies[i].vy;
      bodies[i].z += .01 * bodies[i].vz;
    }
  }
  printf("%.9f\n", energy());
}
