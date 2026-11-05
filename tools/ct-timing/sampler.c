#define _GNU_SOURCE
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <sched.h>
#include <x86intrin.h>
#include <string.h>

struct sample { uint64_t ticks, clazz; };
struct sampler { uint64_t n, start; unsigned aux; size_t size; unsigned char *input; struct sample *sample; };
static uint64_t rng(uint64_t *s) { *s ^= *s << 13; *s ^= *s >> 7; *s ^= *s << 17; return *s; }
intptr_t ctt_init(int64_t count, int64_t size, int64_t seed) {
    cpu_set_t mask; if (sched_getaffinity(0,sizeof mask,&mask) || CPU_COUNT(&mask)!=1) return 0;
    if (count<2 || count>10000000 || (count&1) || size<1 || size>4096) return 0;
    struct sampler *s=calloc(1,sizeof *s); if (!s) return 0;
    s->n=count; s->size=size; s->input=malloc(count*size); s->sample=calloc(count,sizeof *s->sample);
    if (!s->input || !s->sample) { free(s->input); free(s->sample);free(s);return 0; }
    uint64_t state=seed ? (uint64_t)seed : 1;
    for (uint64_t i=0;i<s->n;i++) s->sample[i].clazz=i&1;
    for (uint64_t i=s->n-1;i>0;i--) { uint64_t j=rng(&state)%(i+1); uint64_t c=s->sample[i].clazz;s->sample[i].clazz=s->sample[j].clazz;s->sample[j].clazz=c; }
    for (uint64_t i=0;i<s->n;i++) for (size_t j=0;j<s->size;j++) {
        unsigned char v=(unsigned char)rng(&state);s->input[i*s->size+j]=s->sample[i].clazz?v:0;
    }
    return (intptr_t)s;
}
intptr_t ctt_input(struct sampler *s, int64_t i) { return (intptr_t)(s->input+i*s->size); }
/* No class lookup or input generation in the timing interval. Both boundaries
 * serialize older operations; RDTSCP's AUX identifies migration. TSC ticks are
 * not frequency-dependent core cycles. External calls are compiler barriers. */
void ctt_begin(struct sampler *s,void *data,void *out,void *work) { (void)data;(void)out;(void)work;_mm_mfence();_mm_lfence();s->start=__rdtscp(&s->aux);_mm_lfence(); }
void ctt_end(struct sampler *s,int64_t i,void *data,void *out,void *work,int64_t result) { (void)data;(void)out;(void)work;(void)result;unsigned aux;_mm_mfence();_mm_lfence();uint64_t end=__rdtscp(&aux);_mm_lfence();s->sample[i].ticks=end-s->start;if(aux!=s->aux)s->sample[i].clazz=2; }
int64_t ctt_finish(struct sampler *s) {
    const unsigned char magic[8]={'A','B','L','A','T','S','C','1'};
    int ok=fwrite(magic,1,8,stdout)==8 && fwrite(&s->n,8,1,stdout)==1 && fwrite(s->sample,sizeof *s->sample,s->n,stdout)==s->n && fflush(stdout)==0;
    free(s->input);free(s->sample);free(s);return ok?0:1;
}

static volatile uint64_t sink;
void ctt_consume(const void *p) { uint64_t v;memcpy(&v,p,8);sink^=v; }

int64_t ctt_check_aes(const unsigned char *out) {
    static const unsigned char expected[16]={0x66,0xe9,0x4b,0xd4,0xef,0x8a,0x2c,0x3b,0x88,0x4c,0xfa,0x59,0xca,0x34,0x2b,0x2e};
    return memcmp(out,expected,16)==0;
}
