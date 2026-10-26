/* BSD-3-Clause. Identical lossless delta/shuffle mapping for CPU and Metal.
 * Padding remains untouched. Input pictures stay borrowed/read-only until all
 * queued commands have completed. No image-sized CPU preprocessing buffer. */
#ifndef NEO_METAL_ZSTD_INPUT_H
#define NEO_METAL_ZSTD_INPUT_H
typedef struct NeoRcompGeometry {
    unsigned planes,word_bytes,offset[3],stride[3],width[3],height[3];
} NeoRcompGeometry;
#ifdef __METAL_VERSION__
#define NZI_D device
#define NZI_G constant
#else
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#define NZI_D
#define NZI_G
#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif
#endif
static unsigned char nzi_byte(NZI_D const unsigned char *raw,NZI_G const NeoRcompGeometry *g,unsigned at) {
    for(unsigned p=0;p<g->planes;p++) {
        if(at<g->offset[p])continue;unsigned relative=at-g->offset[p],y=relative/g->stride[p],x=relative%g->stride[p],w=g->width[p];
        if(y>=g->height[p] || x>=w*g->word_bytes)continue;
        NZI_D const unsigned char *row=raw+g->offset[p]+y*g->stride[p];
        if(g->word_bytes==1) {int current=row[x],prev=x?row[x-1]:0,d=(signed char)(current-prev);return (unsigned char)(d>=0?2*d:-2*d-1);}
        unsigned pixel=x<w?x:x-w;int current=row[pixel*2]|(unsigned)row[pixel*2+1]<<8;
        int prev=pixel?(row[pixel*2-2]|(unsigned)row[pixel*2-1]<<8):0,d=current-prev;
        unsigned value=(unsigned short)(d>=0?2*d:-2*d-1);return (unsigned char)(value>>(x<w?0:8));
    }return raw[at];
}
#ifndef __METAL_VERSION__
static int nzi_valid(const NeoRcompGeometry *g,size_t size) {
    if(!g)return 1;if(!g->planes || g->planes>3 || (g->word_bytes!=1 && g->word_bytes!=2))return 0;
    for(unsigned p=0;p<g->planes;p++)if(!g->width[p] || g->width[p]>1920 || !g->height[p] || g->height[p]>1080 ||
        g->stride[p]<g->width[p]*g->word_bytes || (uint64_t)g->offset[p]+(uint64_t)(g->height[p]-1)*g->stride[p]+g->width[p]*g->word_bytes>size)return 0;
    return 1;
}
static void nzi_row(const unsigned char *raw,unsigned char *dst,unsigned w,unsigned word) {
    unsigned x=0;
#if defined(__ARM_NEON)
    if(word==2) {
        uint16x8_t before=vdupq_n_u16(0);
        for(;x+8<=w;x+=8) {uint16x8_t cur=vld1q_u16((const uint16_t*)raw+x),prev=vextq_u16(before,cur,7);before=cur;
            int32x4_t lo=vreinterpretq_s32_u32(vsubl_u16(vget_low_u16(cur),vget_low_u16(prev))),hi=vreinterpretq_s32_u32(vsubl_u16(vget_high_u16(cur),vget_high_u16(prev)));
            uint16x8_t z=vcombine_u16(vmovn_u32(vreinterpretq_u32_s32(veorq_s32(vshlq_n_s32(lo,1),vshrq_n_s32(lo,31)))),vmovn_u32(vreinterpretq_u32_s32(veorq_s32(vshlq_n_s32(hi,1),vshrq_n_s32(hi,31)))));
            vst1_u8(dst+x,vmovn_u16(z));vst1_u8(dst+w+x,vshrn_n_u16(z,8));}
    }else {
        uint8x16_t before=vdupq_n_u8(0);
        for(;x+16<=w;x+=16) {uint8x16_t cur=vld1q_u8(raw+x),prev=vextq_u8(before,cur,15);before=cur;
            int8x16_t d=vreinterpretq_s8_u8(vsubq_u8(cur,prev));vst1q_u8(dst+x,vreinterpretq_u8_s8(veorq_s8(vshlq_n_s8(d,1),vshrq_n_s8(d,7))));}
    }
#endif
    for(;x<w;x++) {
        if(word==1) {int d=(int8_t)(raw[x]-(x?raw[x-1]:0));dst[x]=(uint8_t)(d>=0?2*d:-2*d-1);}
        else {int v=raw[x*2]|(unsigned)raw[x*2+1]<<8,prev=x?(raw[x*2-2]|(unsigned)raw[x*2-1]<<8):0,d=v-prev;unsigned z=(uint16_t)(d>=0?2*d:-2*d-1);dst[x]=(uint8_t)z;dst[w+x]=(uint8_t)(z>>8);}
    }
}
static void nzi_prepare(const unsigned char *raw,const NeoRcompGeometry *g,size_t offset,size_t n,unsigned char *dst) {
    if(!g) {memcpy(dst,raw+offset,n);return;}
    int ordered=1;for(unsigned p=1;p<g->planes;p++)if((size_t)g->offset[p]<(size_t)g->offset[p-1]+(size_t)(g->height[p-1]-1)*g->stride[p-1]+g->width[p-1]*g->word_bytes)ordered=0;
    if(!ordered)memcpy(dst,raw+offset,n);size_t cursor=offset;
    for(unsigned p=0;p<g->planes;p++) {
        size_t plane=g->offset[p],stride=g->stride[p],width=g->width[p]*g->word_bytes,end=offset+n;
        if(end<=plane)continue;size_t first=offset>plane?(offset-plane)/stride:0,last=(end-1-plane)/stride;
        if(last>=g->height[p])last=g->height[p]-1;
        for(size_t y=first;y<=last && y<g->height[p];y++) {
            size_t start=plane+y*stride,stop=start+width;if(stop<=offset || start>=end)continue;
            size_t a=start>offset?start:offset,b=stop<end?stop:end;
            if(ordered && cursor<a)memcpy(dst+cursor-offset,raw+cursor,a-cursor);
            if(start>=offset && stop<=end)nzi_row(raw+start,dst+start-offset,g->width[p],g->word_bytes);
            else for(size_t at=a;at<b;at++)dst[at-offset]=nzi_byte(raw,g,(unsigned)at);
            cursor=b;
        }
    }
    if(ordered && cursor<offset+n)memcpy(dst+cursor-offset,raw+cursor,offset+n-cursor);
}
#endif
#endif
