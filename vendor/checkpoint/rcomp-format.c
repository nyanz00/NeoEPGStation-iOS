/* Private checkpoint container, independent 64KiB LZ4 blocks. BSD-2-Clause. */
#include "rcomp.h"
#include "neo_compression_namespace.h"
#include "lz4.h"
#include <stdlib.h>
#include <string.h>
static void put32(uint8_t *p,uint32_t v) {for(int i=0;i<4;i++)p[i]=(uint8_t)(v>>(8*i));}
static uint32_t get32(const uint8_t *p) {return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
int neo_rcomp_assemble(const uint8_t *padded,size_t size,const uint8_t *slots,
                      const uint32_t *sizes,NeoRcompOutput *out) {
    if(!padded || !slots || !sizes || !out || !size || size>48*1024*1024)return 1001;
    size_t count=(size+NEO_RCOMP_BLOCK-1)/NEO_RCOMP_BLOCK,total=12;
    for(size_t i=0;i<count;i++) {
        if(!sizes[i] || sizes[i]>NEO_RCOMP_SLOT)return 1010;
        total+=4+(sizes[i]<NEO_RCOMP_BLOCK?sizes[i]:NEO_RCOMP_BLOCK);
    }
    uint8_t *bytes=malloc(total);if(!bytes)return 1005;
    memcpy(bytes,"RCM1",4);put32(bytes+4,(uint32_t)size);put32(bytes+8,(uint32_t)count);
    size_t pos=12;
    for(size_t i=0;i<count;i++) {
        int raw=sizes[i]>=NEO_RCOMP_BLOCK;size_t n=raw?NEO_RCOMP_BLOCK:sizes[i];
        put32(bytes+pos,(uint32_t)n|(raw?0x80000000u:0));pos+=4;
        memcpy(bytes+pos,raw?padded+i*NEO_RCOMP_BLOCK:slots+i*NEO_RCOMP_SLOT,n);pos+=n;
    }
    *out=(NeoRcompOutput){bytes,total};return 0;
}
int neo_rcomp_cpu_pack(const NeoRcompInput *in,NeoRcompOutput *out,unsigned count) {
    if(!in || !out || !count || count>8)return 1001;
    for(unsigned j=0;j<count;j++) {
        if(!in[j].data || !in[j].size || in[j].size>48*1024*1024)return 1001;
        size_t blocks=(in[j].size+NEO_RCOMP_BLOCK-1)/NEO_RCOMP_BLOCK,n=blocks*NEO_RCOMP_BLOCK;
        uint8_t *padded=calloc(1,n),*slots=malloc(blocks*NEO_RCOMP_SLOT);
        uint32_t *sizes=malloc(blocks*sizeof(*sizes));
        if(!padded || !slots || !sizes) {free(padded);free(slots);free(sizes);return 1005;}
        memcpy(padded,in[j].data,in[j].size);
        for(size_t k=0;k<blocks;k++)sizes[k]=(uint32_t)LZ4_compress_default(
            (const char*)padded+k*NEO_RCOMP_BLOCK,(char*)slots+k*NEO_RCOMP_SLOT,NEO_RCOMP_BLOCK,NEO_RCOMP_SLOT);
        int e=neo_rcomp_assemble(padded,in[j].size,slots,sizes,&out[j]);
        free(sizes);free(slots);free(padded);if(e)return e;
    }
    return 0;
}
int neo_rcomp_unpack(const uint8_t *data,size_t size,uint8_t *out,size_t raw_size) {
    if(!data || !out || size<12 || memcmp(data,"RCM1",4) || get32(data+4)!=raw_size || !raw_size || raw_size>48*1024*1024)return 1010;
    size_t count=(raw_size+NEO_RCOMP_BLOCK-1)/NEO_RCOMP_BLOCK,pos=12;
    if(get32(data+8)!=count)return 1010;
    uint8_t *tail=malloc(NEO_RCOMP_BLOCK);if(!tail)return 1005;
    int e=0;
    for(size_t k=0;k<count;k++) {
        if(size-pos<4) {e=1010;break;}
        uint32_t header=get32(data+pos);pos+=4;size_t n=header&0x7fffffffu;
        if(!n || n>NEO_RCOMP_SLOT || n>size-pos) {e=1010;break;}
        size_t remain=raw_size-k*NEO_RCOMP_BLOCK,valid=remain<NEO_RCOMP_BLOCK?remain:NEO_RCOMP_BLOCK;
        uint8_t *dest=valid==NEO_RCOMP_BLOCK?out+k*NEO_RCOMP_BLOCK:tail;
        if(header&0x80000000u) {
            if(n!=NEO_RCOMP_BLOCK) {e=1010;break;}
            memcpy(dest,data+pos,n);
        } else if(LZ4_decompress_safe((const char*)data+pos,(char*)dest,(int)n,NEO_RCOMP_BLOCK)!=NEO_RCOMP_BLOCK) {e=1010;break;}
        if(dest==tail)memcpy(out+k*NEO_RCOMP_BLOCK,tail,valid);pos+=n;
    }
    free(tail);return e?e:pos==size?0:1010;
}
#ifndef __APPLE__
int neo_rcomp_begin(double *ms) {if(ms)*ms=0;return 1009;}
void neo_rcomp_end(void) {}
void neo_rcomp_last_metrics(NeoRcompMetrics *out) {memset(out,0,sizeof(*out));}
int neo_rcomp_gpu_pack(const NeoRcompInput *in,NeoRcompOutput *out,unsigned n) {(void)in;(void)out;(void)n;return 1009;}
#endif
