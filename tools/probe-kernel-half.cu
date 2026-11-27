// CUDA C reference for abla/kernel's half-precision conversions (#1302): the device's own conversions on the fixed input
// set of tests/cases/kernel-cuda/src/half.ab, summarised as that file's halfSummary does (FNV-1a per section), which
// tests/cases/kernel/half-cpu.ab records; with --table, one line per input instead, hex, to diff against the CPU's:
//   f <x> <bf16(x)> <f16(x)> <rni(x)> <e4m3x2(x, next)>        (e4m3x2 as __nv_cvt_float2_to_fp8x2(float2{next, x}): x high)
//   e <pair> <f16x2 bits of the e4m3x2 pair>                    (all 65536 pairs)
//   h <a> <b> <c> <hfma2(a,b,c)>                                (f16x2 triples: specials crossed, then xorshift)
#include <cuda_bf16.h>
#include <cuda_fp16.h>
#include <cuda_fp8.h>
#include <cstdio>
#include <cstdint>
#include <initializer_list>
#include <string>
#include <vector>

static uint32_t state = 2463534242u;
static uint32_t next32() { state ^= state << 13; state ^= state >> 17; state ^= state << 5; return state; }

static const uint32_t specials[] = {
    0x00000000u, 0x80000000u, 0x7f800000u, 0xff800000u, 0x7fc00000u, 0xffc00000u, 0x7f800001u, 0xff800001u,
    0x7fbfffffu, 0x7fffffffu, 0xffffffffu, 0x7fc00001u, 0x00000001u, 0x80000001u, 0x007fffffu, 0x00800000u,
    0x3f800000u, 0xbf800000u, 0x43e00000u, 0x43e80000u, 0x43f00000u, 0xc3e00000u, 0xc3f00000u, 0x477fe000u,
    0x477ff000u, 0x477fefffu, 0x47800000u, 0x33800000u, 0x33000000u, 0x33000001u, 0x3b000000u, 0x3a800000u,
    0x3b100000u, 0x4f000000u, 0xcf000000u, 0x4effffffu, 0xcf000001u, 0x3f000000u, 0x3fc00000u, 0x40200000u,
    0xbf000000u, 0xbfc00000u, 0x7f7fffffu, 0xff7fffffu,
};
static const uint32_t mantissas[] = {
    0x000000u, 0x000001u, 0x000002u, 0x000003u, 0x7fffffu, 0x7ffffeu, 0x400000u, 0x3fffffu, 0x000fffu, 0x001000u,
    0x001001u, 0x001fffu, 0x002000u, 0x003000u, 0x007fffu, 0x008000u, 0x008001u, 0x018000u, 0x017fffu, 0x010000u,
    0x7f8000u, 0x7fc000u, 0x080000u, 0x080001u, 0x07ffffu, 0x180000u, 0x100000u, 0x17ffffu, 0x280000u, 0x700000u,
    0x780000u, 0x77ffffu, 0x600000u, 0x680000u,
};

std::vector<uint32_t> f32Inputs() {
    std::vector<uint32_t> v(specials, specials + sizeof specials / 4);
    for (uint32_t sign = 0; sign < 2; sign++)
        for (uint32_t e = 0; e < 256; e++)
            for (uint32_t m : mantissas) v.push_back(sign << 31 | e << 23 | m);
    for (int i = 0; i < (1 << 18); i++) v.push_back(next32());
    return v;
}

__global__ void f32Kernel(const uint32_t *x, uint32_t *out, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    float a = __uint_as_float(x[i]), b = __uint_as_float(x[(i + 1) % n]);
    out[4 * i] = __bfloat16_as_ushort(__float2bfloat16_rn(a));
    out[4 * i + 1] = __half_as_ushort(__float2half_rn(a));
    out[4 * i + 2] = (uint32_t)__float2int_rn(a);
    out[4 * i + 3] = __nv_cvt_float2_to_fp8x2(make_float2(b, a), __NV_SATFINITE, __NV_E4M3);
}

__global__ void e4m3Kernel(uint32_t *out) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= 65536) return;
    __half2_raw r = __nv_cvt_fp8x2_to_halfraw2((__nv_fp8x2_storage_t)i, __NV_E4M3);
    out[i] = (uint32_t)r.x | (uint32_t)r.y << 16;
}

__global__ void hfmaKernel(const uint32_t *abc, uint32_t *out, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    __half2 a = *reinterpret_cast<const __half2 *>(&abc[3 * i]);
    __half2 b = *reinterpret_cast<const __half2 *>(&abc[3 * i + 1]);
    __half2 c = *reinterpret_cast<const __half2 *>(&abc[3 * i + 2]);
    __half2 r = __hfma2(a, b, c);
    out[i] = *reinterpret_cast<uint32_t *>(&r);
}

template <class T> T *device(const std::vector<T> &host) {
    T *d; cudaMalloc(&d, host.size() * sizeof(T)); cudaMemcpy(d, host.data(), host.size() * sizeof(T), cudaMemcpyHostToDevice); return d;
}

static uint32_t hashes[3] = {2166136261u, 2166136261u, 2166136261u};
static bool table = false;
static void entry(int section, const char *tag, std::initializer_list<uint32_t> words, std::initializer_list<int> digits) {
    if (table) printf("%s", tag);
    auto d = digits.begin();
    for (uint32_t w : words) {
        if (table) printf(" %0*x", *d++, w);
        for (int k = 0; k < 4; k++) hashes[section] = (hashes[section] ^ ((w >> (8 * k)) & 255)) * 16777619u;
    }
    if (table) printf("\n");
}

int main(int argc, char **argv) {
    table = argc > 1 && std::string(argv[1]) == "--table";
    std::vector<uint32_t> x = f32Inputs();
    int n = (int)x.size();
    uint32_t *dx = device(x), *dout;
    cudaMalloc(&dout, 4 * 4 * (size_t)n);
    f32Kernel<<<(n + 255) / 256, 256>>>(dx, dout, n);
    std::vector<uint32_t> out(4 * (size_t)n);
    cudaMemcpy(out.data(), dout, out.size() * 4, cudaMemcpyDeviceToHost);
    for (int i = 0; i < n; i++)
        entry(0, "f", {x[i], out[4 * i], out[4 * i + 1], out[4 * i + 2], out[4 * i + 3]}, {8, 4, 4, 8, 4});
    uint32_t *de; cudaMalloc(&de, 65536 * 4);
    e4m3Kernel<<<256, 256>>>(de);
    std::vector<uint32_t> e(65536);
    cudaMemcpy(e.data(), de, 65536 * 4, cudaMemcpyDeviceToHost);
    for (int i = 0; i < 65536; i++) entry(1, "e", {(uint32_t)i, e[i]}, {4, 8});
    // f16 specials: +-0, +-min denormal, +-max denormal, +-min normal, 1, -1, 0.5, max, inf, NaNs, 2^-24 * 3, 65504 neighbours
    const uint16_t hs[] = {0x0000, 0x8000, 0x0001, 0x8001, 0x03ff, 0x83ff, 0x0400, 0x3c00, 0xbc00, 0x3800, 0x7bff,
                           0xfbff, 0x7c00, 0xfc00, 0x7e00, 0x7c01, 0xfe01, 0x7fff, 0x0003, 0x3555, 0x5bff, 0x1400};
    const int hn = sizeof hs / 2;
    std::vector<uint32_t> abc;
    for (int i = 0; i < hn; i++)
        for (int j = 0; j < hn; j++)
            for (int k = 0; k < hn; k++) {
                abc.push_back(hs[i] | (uint32_t)hs[j] << 16);
                abc.push_back(hs[j] | (uint32_t)hs[k] << 16);
                abc.push_back(hs[k] | (uint32_t)hs[i] << 16);
            }
    for (int i = 0; i < 3 * (1 << 18); i++) abc.push_back(next32());
    int m = (int)abc.size() / 3;
    uint32_t *dabc = device(abc), *dh;
    cudaMalloc(&dh, 4 * (size_t)m);
    hfmaKernel<<<(m + 255) / 256, 256>>>(dabc, dh, m);
    std::vector<uint32_t> h(m);
    cudaMemcpy(h.data(), dh, 4 * (size_t)m, cudaMemcpyDeviceToHost);
    cudaError_t error = cudaGetLastError();
    if (error != cudaSuccess) { fprintf(stderr, "cuda: %s\n", cudaGetErrorString(error)); return 1; }
    for (int i = 0; i < m; i++) entry(2, "h", {abc[3 * i], abc[3 * i + 1], abc[3 * i + 2], h[i]}, {8, 8, 8, 8});
    // bf16 -> f32 is a shift on every backend: half.ab checks it in place ("bf16 exact").
    if (!table) printf("f %d %08x e 65536 %08x h %d %08x bf16 exact true\n", n, hashes[0], hashes[1], m, hashes[2]);
    return 0;
}
