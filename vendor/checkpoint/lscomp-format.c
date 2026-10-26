/* Copyright (c) 2025 UChicago Argonne and University of Iowa.
 * Adapted lossless lsCOMP bit planes; original license: vendor/lscomp/LICENSE.
 * Quantization=1 and no pooling. New bounded container and CPU reference. */
#include "lscomp.h"
#include <stdlib.h>
#include <string.h>
static void put32(uint8_t *p,uint32_t v) {for(int j=0;j<4;j++)p[j]=(uint8_t)(v>>(8*j));}
static uint32_t get32(const uint8_t *p) {return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
int neo_lscomp_geometry(const NeoRcompInput *in,NeoLsImage *g) {
    if(!in || !g || !in->data || !in->size || in->size>48*1024*1024 ||
       !in->row_width || in->row_width>16384 || (in->word_bytes!=1 && in->word_bytes!=2) || in->size%in->word_bytes)return 1001;
    size_t words=in->size/in->word_bytes,h=(words+in->row_width-1)/in->row_width;
    size_t cols=(in->row_width+7)/8,rows=(h+7)/8,tiles=cols*rows;
    if(tiles>1024*1024)return 1005;
    *g=(NeoLsImage){(uint32_t)in->size,in->row_width,in->word_bytes,0,0,(uint32_t)cols,(uint32_t)rows,(uint32_t)tiles};return 0;
}
static unsigned sample(const NeoRcompInput *in,const NeoLsImage *g,size_t tile,int k) {
    size_t x=(tile%g->tile_columns)*8+(k%8),y=(tile/g->tile_columns)*8+(k/8),i=y*g->row_width+x;
    if(x>=g->row_width || i>=g->raw_bytes/g->word_bytes)return 0;
    size_t p=i*g->word_bytes;return in->data[p]|(g->word_bytes==2?(unsigned)in->data[p+1]<<8:0);
}
int neo_lscomp_assemble(const NeoLsImage *g,const uint8_t *widths,const uint8_t *payload,size_t payload_size,NeoRcompOutput *out) {
    if(!g || !widths || !out || !g->tiles || g->tiles>1024*1024 || (g->word_bytes!=1 && g->word_bytes!=2))return 1001;
    size_t actual=0;for(uint32_t t=0;t<g->tiles;t++) {if(widths[t]>g->word_bytes*8)return 1010;actual+=(size_t)widths[t]*8;}
    if(actual!=payload_size || (actual && !payload))return 1010;
    size_t header=24+((g->tiles+3u)&~3u),n=header+actual;
    if(n>96*1024*1024)return 1005;
    uint8_t *data=calloc(1,n);if(!data)return 1005;
    memcpy(data,"LSC1",4);put32(data+4,g->raw_bytes);put32(data+8,g->row_width);put32(data+12,g->word_bytes);put32(data+16,g->tiles);
    memcpy(data+24,widths,g->tiles);if(actual)memcpy(data+header,payload,actual);
    *out=(NeoRcompOutput){data,n};return 0;
}
int neo_lscomp_cpu_pack(const NeoRcompInput *in,NeoRcompOutput *out,unsigned count) {
    if(!in || !out || !count || count>8)return 1001;
    for(unsigned j=0;j<count;j++) {
        NeoLsImage g;int e=neo_lscomp_geometry(&in[j],&g);if(e)return e;
        uint8_t *widths=malloc(g.tiles);if(!widths)return 1005;size_t n=0;
        for(uint32_t t=0;t<g.tiles;t++) {
            unsigned maximum=0,bits=0;for(int k=0;k<64;k++) {unsigned v=sample(&in[j],&g,t,k);if(v>maximum)maximum=v;}
            while(maximum) {bits++;maximum>>=1;}widths[t]=(uint8_t)bits;n+=bits*8;
        }
        uint8_t *payload=malloc(n?n:1);if(!payload) {free(widths);return 1005;}size_t pos=0;
        for(uint32_t t=0;t<g.tiles;t++) {
            unsigned values[64];for(int k=0;k<64;k++)values[k]=sample(&in[j],&g,t,k);
            for(unsigned bit=0;bit<widths[t];bit++)for(int lane=0;lane<8;lane++) {
                unsigned byte=0;for(int k=0;k<8;k++)byte|=((values[lane*8+k]>>bit)&1u)<<(7-k);
                payload[pos++]=(uint8_t)byte;
            }
        }
        e=neo_lscomp_assemble(&g,widths,payload,n,&out[j]);free(payload);free(widths);if(e)return e;
    }
    return 0;
}
int neo_lscomp_unpack(const uint8_t *data,size_t size,uint8_t *out,size_t raw_size) {
    if(!data || !out || size<24 || memcmp(data,"LSC1",4) || get32(data+4)!=raw_size || get32(data+20))return 1010;
    NeoRcompInput in={out,raw_size,get32(data+8),get32(data+12)};NeoLsImage g;
    if(neo_lscomp_geometry(&in,&g) || get32(data+16)!=g.tiles)return 1010;
    size_t pos=24+((g.tiles+3u)&~3u);if(pos>size)return 1010;
    for(uint32_t t=0;t<g.tiles;t++) {
        unsigned bits=data[24+t];if(bits>g.word_bytes*8 || bits*8>size-pos)return 1010;
        unsigned v[64]={0};
        for(unsigned b=0;b<bits;b++)for(int lane=0;lane<8;lane++) {
            unsigned byte=data[pos++];for(int k=0;k<8;k++)v[lane*8+k]|=((byte>>(7-k))&1u)<<b;
        }
        for(int k=0;k<64;k++) {
            size_t x=(t%g.tile_columns)*8+(k%8),y=(t/g.tile_columns)*8+(k/8),i=y*g.row_width+x;
            if(x<g.row_width && i<raw_size/g.word_bytes) {
                out[i*g.word_bytes]=(uint8_t)v[k];if(g.word_bytes==2)out[i*2+1]=(uint8_t)(v[k]>>8);
            }
        }
    }
    return pos==size?0:1010;
}
#ifndef __APPLE__
int neo_lscomp_begin(double *ms) {if(ms)*ms=0;return 1009;}
void neo_lscomp_end(void) {}
void neo_lscomp_last_metrics(NeoRcompMetrics *out) {memset(out,0,sizeof(*out));}
int neo_lscomp_gpu_pack(const NeoRcompInput *in,NeoRcompOutput *out,unsigned n) {(void)in;(void)out;(void)n;return 1009;}
#endif
