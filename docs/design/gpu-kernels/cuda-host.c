/* Spike: runs kernels.ptx (vadd, nvfp4dot) through the CUDA driver API (declared by hand, as Abla's bindings would), the
   same bodies on the CPU (kernels-cpu.o), and an independent C reference of the NVFP4 decode; compares and times them. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include <time.h>
typedef int CUresult; typedef int CUdevice; typedef void *CUcontext, *CUmodule, *CUfunction, *CUstream; typedef unsigned long long CUdeviceptr;
CUresult cuInit(unsigned); CUresult cuDeviceGet(CUdevice *, int); CUresult cuDeviceGetName(char *, int, CUdevice);
CUresult cuCtxCreate_v2(CUcontext *, unsigned, CUdevice); CUresult cuModuleLoadData(CUmodule *, const void *);
CUresult cuModuleGetFunction(CUfunction *, CUmodule, const char *); CUresult cuMemAlloc_v2(CUdeviceptr *, size_t);
CUresult cuMemcpyHtoD_v2(CUdeviceptr, const void *, size_t); CUresult cuMemcpyDtoH_v2(void *, CUdeviceptr, size_t);
CUresult cuLaunchKernel(CUfunction, unsigned, unsigned, unsigned, unsigned, unsigned, unsigned, unsigned, CUstream, void **, void **);
CUresult cuCtxSynchronize(void); CUresult cuGetErrorString(CUresult, const char **);
#define CK(x) do { CUresult r_ = (x); if (r_) { const char *s_ = "?"; cuGetErrorString(r_, &s_); fprintf(stderr, "%s: %d %s\n", #x, r_, s_); exit(1); } } while (0)
void vadd_cpu(float *, float *, float *, int); void nvfp4dot_cpu(uint8_t *, uint8_t *, float *, float *, int, int, float);
void nvfp4dotSub_cpu(uint8_t *, uint8_t *, float *, float *, int, int, float);
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }
static float refE2m1(int n) { static const float m[8] = { 0, 0.5f, 1, 1.5f, 2, 3, 4, 6 }; return (n & 8) ? -m[n & 7] : m[n & 7]; }
static float refE4m3(int b) { int e = (b >> 3) & 15, m = b & 7; return e == 0 ? ldexpf((float)m / 8, -6) : ldexpf(1 + (float)m / 8, e - 7); }
static char *readAll(const char *p) { FILE *f = fopen(p, "rb"); fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET); char *d = calloc(n + 1, 1); if (fread(d, 1, n, f) != (size_t)n) exit(1); fclose(f); return d; }
static uint64_t seed = 88172645463325252ull; static uint32_t rnd(void) { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return (uint32_t)seed; }
int main(void) {
    CK(cuInit(0)); CUdevice dev; CK(cuDeviceGet(&dev, 0)); char name[128]; CK(cuDeviceGetName(name, 128, dev)); printf("device: %s\n", name);
    CUcontext ctx; CK(cuCtxCreate_v2(&ctx, 0, dev));
    CUmodule mod; CK(cuModuleLoadData(&mod, readAll("kernels.ptx")));
    CUfunction fvadd, fdot; CK(cuModuleGetFunction(&fvadd, mod, "vadd")); CK(cuModuleGetFunction(&fdot, mod, "nvfp4dot"));
    CUfunction fsub; CK(cuModuleGetFunction(&fsub, mod, "nvfp4dotSub"));
    /* vadd */
    int n = 1 << 20; float *a = malloc(n * 4), *b = malloc(n * 4), *c = malloc(n * 4), *cc = malloc(n * 4);
    for (int i = 0; i < n; i++) { a[i] = i * 0.5f; b[i] = 1000 - i; }
    CUdeviceptr da, db, dc; CK(cuMemAlloc_v2(&da, n * 4)); CK(cuMemAlloc_v2(&db, n * 4)); CK(cuMemAlloc_v2(&dc, n * 4));
    CK(cuMemcpyHtoD_v2(da, a, n * 4)); CK(cuMemcpyHtoD_v2(db, b, n * 4));
    void *va[] = { &da, &db, &dc, &n }; CK(cuLaunchKernel(fvadd, (n + 255) / 256, 1, 1, 256, 1, 1, 0, 0, va, 0)); CK(cuCtxSynchronize());
    CK(cuMemcpyDtoH_v2(c, dc, n * 4)); vadd_cpu(a, b, cc, n);
    int bad = 0; for (int i = 0; i < n; i++) if (c[i] != a[i] + b[i] || cc[i] != c[i]) bad++;
    printf("vadd: %d elements, GPU and CPU equal to a+b: %s\n", n, bad ? "NO" : "yes");
    /* nvfp4 dot: rows x k */
    int rows = 8192, k = 4096; float g = 0.0125f;
    size_t wbytes = (size_t)rows * k / 2, sbytes = (size_t)rows * k / 16;
    uint8_t *w = malloc(wbytes), *s = malloc(sbytes); float *x = malloc(k * 4), *og = malloc(rows * 4), *oc = malloc(rows * 4), *orf = malloc(rows * 4);
    for (size_t i = 0; i < wbytes; i++) w[i] = rnd();
    for (size_t i = 0; i < sbytes; i++) s[i] = (uint8_t)(((4 + rnd() % 6) << 3) | (rnd() & 7)); /* exponents 4..9 */
    for (int i = 0; i < k; i++) x[i] = ((int)(rnd() % 2001) - 1000) / 1000.0f;
    s[0] = 0x05; /* one subnormal scale */
    CUdeviceptr dw, ds, dx, dout; CK(cuMemAlloc_v2(&dw, wbytes)); CK(cuMemAlloc_v2(&ds, sbytes)); CK(cuMemAlloc_v2(&dx, k * 4)); CK(cuMemAlloc_v2(&dout, rows * 4));
    CK(cuMemcpyHtoD_v2(dw, w, wbytes)); CK(cuMemcpyHtoD_v2(ds, s, sbytes)); CK(cuMemcpyHtoD_v2(dx, x, k * 4));
    void *vd[] = { &dw, &ds, &dx, &dout, &rows, &k, &g };
    CK(cuLaunchKernel(fdot, (rows + 127) / 128, 1, 1, 128, 1, 1, 0, 0, vd, 0)); CK(cuCtxSynchronize());
    double t0 = now(); int reps = 50;
    for (int r = 0; r < reps; r++) CK(cuLaunchKernel(fdot, (rows + 127) / 128, 1, 1, 128, 1, 1, 0, 0, vd, 0));
    CK(cuCtxSynchronize()); double tg = (now() - t0) / reps;
    CK(cuMemcpyDtoH_v2(og, dout, rows * 4));
    t0 = now(); nvfp4dot_cpu(w, s, x, oc, rows, k, g); double tc = now() - t0;
    for (int r = 0; r < rows; r++) { double acc = 0; for (int bl = 0; bl < k / 16; bl++) { double bs = 0; for (int j = 0; j < 16; j++) { int byte = w[(size_t)r * k / 2 + bl * 8 + j / 2]; int nib = (j & 1) ? byte >> 4 : byte & 15; bs += (double)refE2m1(nib) * x[bl * 16 + j]; } acc += refE4m3(s[(size_t)r * k / 16 + bl]) * bs; } orf[r] = (float)(acc * g); }
    double maxg = 0, maxc = 0, scale = 0;
    for (int r = 0; r < rows; r++) { scale = fmax(scale, fabs(orf[r])); maxg = fmax(maxg, fabs(og[r] - orf[r])); maxc = fmax(maxc, fabs(oc[r] - orf[r])); }
    printf("nvfp4dot: %d x %d, max |GPU - reference| %.3g, max |CPU - reference| %.3g (outputs up to %.3g); row 0 %g %g %g\n", rows, k, maxg, maxc, scale, og[0], oc[0], orf[0]);
    printf("time: GPU %.1f us per call (%.0f GB/s of weights+scales), CPU one thread %.1f ms\n", tg * 1e6, (wbytes + sbytes) / tg / 1e9, tc * 1e3);
    /* one warp per row */
    float *os = malloc(rows * 4), *ocs = malloc(rows * 4); CK(cuLaunchKernel(fsub, rows * 32 / 256, 1, 1, 256, 1, 1, 0, 0, vd, 0)); CK(cuCtxSynchronize());
    t0 = now(); for (int r = 0; r < reps; r++) CK(cuLaunchKernel(fsub, rows * 32 / 256, 1, 1, 256, 1, 1, 0, 0, vd, 0)); CK(cuCtxSynchronize()); double ts = (now() - t0) / reps;
    CK(cuMemcpyDtoH_v2(os, dout, rows * 4)); nvfp4dotSub_cpu(w, s, x, ocs, rows, k, g);
    double ms = 0, mcs = 0; for (int r = 0; r < rows; r++) { ms = fmax(ms, fabs(os[r] - orf[r])); mcs = fmax(mcs, fabs(ocs[r] - orf[r])); }
    printf("nvfp4dotSub (one subgroup per row): max |GPU - reference| %.3g, max |CPU - reference| %.3g; GPU %.1f us per call (%.0f GB/s)\n", ms, mcs, ts * 1e6, (wbytes + sbytes) / ts / 1e9);
    return 0;
}
