/* Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.
 * BSD-3-Clause. Zstandard format/FSE arithmetic adapted from Meta Zstandard
 * 1.5.7 (lib/common/fse.h, lib/compress/fse_compress.c,
 * zstd_compress_sequences.c and huf_compress.c). See Zstandard-LICENSE.
 * New bounded encoder, Metal address spaces and heap Huffman builder.
 * No gpu-zstd-comp source is incorporated or translated. */
#ifndef NEO_METAL_ZSTD_CORE_H
#define NEO_METAL_ZSTD_CORE_H
#ifdef __METAL_VERSION__
#define NZ_D device
#define NZ_T thread
#define NZ_C constant
typedef ulong Nz64;
#else
#include <stdint.h>
#define NZ_D
#define NZ_T
#define NZ_C static const
typedef uint64_t Nz64;
#endif
typedef unsigned int NzU;
typedef unsigned char NzB;
#define NZ_BLOCK 65536u
#define NZ_HASH 32768u
#define NZ_SLOT (NZ_BLOCK+1024u)
typedef struct NzSeq {NzU ll,ml,off;} NzSeq;
typedef struct NzBits {NZ_D NzB *p; Nz64 bits; NzU used,n;} NzBits;
static void nz_bits(NZ_T NzBits *b,NzU v,NzU n) {
    if(!n)return;b->bits|=((Nz64)v&(((Nz64)1<<n)-1))<<b->used;b->used+=n;
    while(b->used>=8) {b->p[b->n++]=(NzB)b->bits;b->bits>>=8;b->used-=8;}
}
static NzU nz_end(NZ_T NzBits *b,int stop) {if(stop)nz_bits(b,1,1);if(b->used)b->p[b->n++]=(NzB)b->bits;return b->n;}
static NzU nz_log(NzU n) {NzU k=0;while(n>>1) {n>>=1;k++;}return k;}
static void nz_le(NZ_D NzB *p,NzU value,NzU bytes) {for(NzU j=0;j<bytes;j++)p[j]=(NzB)(value>>(8*j));}
static NzU nz_hash(NZ_D const NzB *p) {NzU v=(NzU)p[0]|(NzU)p[1]<<8|(NzU)p[2]<<16|(NzU)p[3]<<24;return (v*2654435761u)>>(32-15);}
typedef struct NzFse {NzU state[64],bits[64],log;int find[64];} NzFse;
static int nz_table(NZ_T NzFse *f,NZ_T const int *norm,NzU symbols,NzU log) {
    NzU size=1u<<log,high=size-1,pos=0,total=0,cumul[65],spread[64];f->log=log;cumul[0]=0;
    for(NzU s=0;s<symbols;s++) {NzU count=norm[s]<0?1:(NzU)norm[s];cumul[s+1]=cumul[s]+count;if(norm[s]<0)spread[high--]=s;}
    if(cumul[symbols]!=size)return 0;
    for(NzU s=0;s<symbols;s++)for(int k=0;k<norm[s];k++) {
        spread[pos]=s;pos=(pos+(size>>1)+(size>>3)+3)&(size-1);while(pos>high)pos=(pos+(size>>1)+(size>>3)+3)&(size-1);
    }
    if(pos)return 0;
    for(NzU j=0;j<size;j++)f->state[cumul[spread[j]]++]=size+j;
    for(NzU s=0;s<symbols;s++) {
        NzU count=norm[s]<0?1:(NzU)norm[s];
        if(!count) {f->bits[s]=((log+1)<<16)-size;f->find[s]=0;continue;}
        NzU n=count==1?log:log-nz_log(count-1);f->bits[s]=(n<<16)-(count<<n);f->find[s]=(int)total-(int)count;total+=count;
    }return 1;
}
static NzU nz_init(NZ_T const NzFse *f,NzU symbol) {if(!f->log)return 0;NzU n=(f->bits[symbol]+(1u<<15))>>16,v=(n<<16)-f->bits[symbol];return f->state[(int)(v>>n)+f->find[symbol]];}
static void nz_symbol(NZ_T NzBits *b,NZ_T const NzFse *f,NZ_T NzU *state,NzU symbol) {
    if(!f->log)return;NzU n=(*state+f->bits[symbol])>>16;nz_bits(b,*state,n);*state=f->state[(int)(*state>>n)+f->find[symbol]];
}
NZ_C NzU nz_llbits[36]={0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,2,2,3,3,4,6,7,8,9,10,11,12,13,14,15,16};
NZ_C NzU nz_mlbits[53]={0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,2,2,3,3,4,4,5,7,8,9,10,11,12,13,14,15,16};
static NzU nz_llcode(NzU value) {NzU base=0;for(NzU c=0;c<35;c++) {NzU next=base+(1u<<nz_llbits[c]);if(value<next)return c;base=next;}return 35;}
static NzU nz_mlcode(NzU value) {NzU base=0;for(NzU c=0;c<52;c++) {NzU next=base+(1u<<nz_mlbits[c]);if(value<next)return c;base=next;}return 52;}
static NzU nz_ncount(NZ_D NzB *,NZ_T const int *,NzU,NzU);
static NzU nz_seqtable(NZ_D NzB *out,NZ_T NzFse *f,NZ_T const NzU *count,NzU total,NZ_T NzU *mode) {
    NzU max=0,biggest=0,sum=0;int norm[64]={0};
    for(NzU j=0;j<64;j++)if(count[j]) {max=j;if(count[j]>count[biggest])biggest=j;norm[j]=(int)(count[j]*64/total);if(!norm[j])norm[j]=1;sum+=(NzU)norm[j];}
    if(count[biggest]==total) {out[0]=(NzB)biggest;f->log=0;*mode=1;return 1;}
    while(sum>64) {NzU best=biggest;for(NzU j=0;j<=max;j++)if(norm[j]>norm[best])best=j;norm[best]--;sum--;}
    norm[biggest]+=(int)(64-sum);NzU size=nz_ncount(out,norm,max+1,6);nz_table(f,norm,max+1,6);*mode=2;return size;
}
static NzU nz_sequences(NZ_D NzB *out,NZ_D const NzSeq *seq,NzU n) {
    NzU p=0;if(n<128)out[p++]=(NzB)n;else if(n<32512) {out[p++]=(NzB)(128+(n>>8));out[p++]=(NzB)n;}else {out[p++]=255;nz_le(out+p,n-32512,2);p+=2;}
    if(!n)return p;NzU header=p++;NzFse ll,ml,of;NzU lc[64]={0},mc[64]={0},oc[64]={0},lm,mm,om;
    for(NzU j=0;j<n;j++) {lc[nz_llcode(seq[j].ll)]++;mc[nz_mlcode(seq[j].ml)]++;oc[nz_log(seq[j].off)]++;}
    p+=nz_seqtable(out+p,&ll,lc,n,&lm);p+=nz_seqtable(out+p,&of,oc,n,&om);p+=nz_seqtable(out+p,&ml,mc,n,&mm);out[header]=(NzB)((lm<<6)|(om<<4)|(mm<<2));
    NzSeq s=seq[n-1];NzU l=nz_llcode(s.ll),m=nz_mlcode(s.ml),o=nz_log(s.off);
    NzU ls=nz_init(&ll,l),ms=nz_init(&ml,m),os=nz_init(&of,o);NzBits bits={out+p,0,0,0};
    nz_bits(&bits,s.ll,nz_llbits[l]);nz_bits(&bits,s.ml,nz_mlbits[m]);nz_bits(&bits,s.off,o);
    for(NzU j=n-1;j>0;) {s=seq[--j];l=nz_llcode(s.ll);m=nz_mlcode(s.ml);o=nz_log(s.off);
        nz_symbol(&bits,&of,&os,o);nz_symbol(&bits,&ml,&ms,m);nz_symbol(&bits,&ll,&ls,l);
        nz_bits(&bits,s.ll,nz_llbits[l]);nz_bits(&bits,s.ml,nz_mlbits[m]);nz_bits(&bits,s.off,o);
    }
    nz_bits(&bits,ms,ml.log);nz_bits(&bits,os,of.log);nz_bits(&bits,ls,ll.log);return p+nz_end(&bits,1);
}
/* Normalized-count header and two-state FSE stream for Huffman weights. */
static NzU nz_ncount(NZ_D NzB *out,NZ_T const int *norm,NzU symbols,NzU log) {
    NzBits b={out,0,0,0};nz_bits(&b,log-5,4);int remaining=(1<<log)+1,threshold=1<<log,nb=(int)log+1,zero=0;NzU s=0;
    while(s<symbols && remaining>1) {
        if(zero) {NzU run=0;while(s<symbols && !norm[s]) {s++;run++;}if(s==symbols)return 0;
            while(run>=24) {nz_bits(&b,65535,16);run-=24;}while(run>=3) {nz_bits(&b,3,2);run-=3;}nz_bits(&b,run,2);
        }
        int count=norm[s++],maximum=2*threshold-1-remaining;remaining-=count<0?-count:count;count++;
        if(count>=threshold)count+=maximum;nz_bits(&b,(NzU)count,(NzU)(nb-(count<maximum)));zero=count==1;
        while(remaining<threshold) {nb--;threshold>>=1;}
    }return remaining==1?nz_end(&b,0):0;
}
static NzU nz_weights(NZ_D NzB *out,NZ_T const NzU *weights,NzU n) {
    NzU counts[16]={0},max=0,kinds=0;int norm[64]={0};for(NzU j=0;j<n;j++) {counts[weights[j]]++;if(weights[j]>max)max=weights[j];}
    NzU sum=0,biggest=0;for(NzU j=0;j<=max;j++)if(counts[j]) {norm[j]=(int)(counts[j]*64/n);if(!norm[j])norm[j]=1;sum+=(NzU)norm[j];kinds++;if(counts[j]>counts[biggest])biggest=j;}
    if(kinds<2)return 0;
    while(sum>64) {NzU best=biggest;for(NzU j=0;j<=max;j++)if(norm[j]>norm[best])best=j;if(norm[best]<=1)return 0;norm[best]--;sum--;}
    norm[biggest]+=(int)(64-sum);NzU header=nz_ncount(out,norm,max+1,6);if(!header)return 0;NzFse f;if(!nz_table(&f,norm,max+1,6))return 0;
    NzBits bits={out+header,0,0,0};NzU at=n,a,b;
    if(n&1) {a=nz_init(&f,weights[--at]);b=nz_init(&f,weights[--at]);nz_symbol(&bits,&f,&a,weights[--at]);}
    else {b=nz_init(&f,weights[--at]);a=nz_init(&f,weights[--at]);}
    while(at) {nz_symbol(&bits,&f,&b,weights[--at]);nz_symbol(&bits,&f,&a,weights[--at]);}
    nz_bits(&bits,b,6);nz_bits(&bits,a,6);return header+nz_end(&bits,1);
}
static NzU nz_pop(NZ_T NzU *heap,NZ_T NzU *count,NZ_T NzU *size) {
    NzU result=heap[0],v=heap[--*size],at=0;while(at*2+1<*size) {NzU child=at*2+1;if(child+1<*size && count[heap[child+1]]<count[heap[child]])child++;if(count[v]<=count[heap[child]])break;heap[at]=heap[child];at=child;}heap[at]=v;return result;
}
static void nz_push(NZ_T NzU *heap,NZ_T NzU *count,NZ_T NzU *size,NzU value) {NzU at=(*size)++;while(at && count[heap[(at-1)/2]]>count[value]) {heap[at]=heap[(at-1)/2];at=(at-1)/2;}heap[at]=value;}
static NzU nz_huffman(NZ_D NzB *out,NZ_D const NzB *literals,NzU n) {
    if(n<64)return 0;NzU hist[256]={0},counts[512],parent[512],heap[512],length[256],codes[256],rank[16],base[16],weights[256];
    for(NzU j=0;j<n;j++)hist[literals[j]]++;
    NzU maxbits=0;
    for(NzU floor=1;floor<=256;floor*=2) {
        NzU size=0,next=256;for(NzU j=0;j<256;j++) {counts[j]=hist[j]>floor?hist[j]:floor;nz_push(heap,counts,&size,j);}
        while(size>1) {NzU a=nz_pop(heap,counts,&size),b=nz_pop(heap,counts,&size);counts[next]=counts[a]+counts[b];parent[a]=parent[b]=next;nz_push(heap,counts,&size,next++);}
        NzU root=heap[0];maxbits=0;for(NzU j=0;j<256;j++) {NzU k=j,b=0;while(k!=root) {b++;k=parent[k];}length[j]=b;if(b>maxbits)maxbits=b;}
        if(maxbits<=11)break;
    }if(maxbits>11)return 0;
    for(NzU j=0;j<16;j++)rank[j]=0;for(NzU j=0;j<256;j++)rank[length[j]]++;
    NzU minimum=0;for(NzU k=maxbits;k>0;k--) {base[k]=minimum;minimum=(minimum+rank[k])>>1;}
    for(NzU j=0;j<256;j++) {codes[j]=base[length[j]]++;weights[j]=maxbits+1-length[j];}
    NzU h=nz_weights(out+1,weights,255);if(!h || h>=128)return 0;out[0]=(NzB)h;h++;
    NzU pos=h+6,quarter=(n+3)/4;
    for(NzU stream=0;stream<4;stream++) {NzU begin=stream*quarter,end=begin+quarter;if(end>n)end=n;NzBits b={out+pos,0,0,0};
        for(NzU j=end;j>begin;) {NzU symbol=literals[--j];nz_bits(&b,codes[symbol],length[symbol]);}
        NzU size=nz_end(&b,1);if(stream<3)nz_le(out+h+stream*2,size,2);pos+=size;
    }return pos;
}
/* Work slices: 16K sequence slots, 64KiB literals, 96KiB Huffman scratch.
 * Compression, including entropy coding/frame construction, is called on GPU. */
static NzU nz_block(NZ_D const NzB *input,NzU n,NZ_D const NzU *matches,
    NZ_D NzSeq *seq,NZ_D NzB *literals,NZ_D NzB *huffman,NZ_D NzB *out) {
    NzU at=0,anchor=0,ns=0,nl=0;
    while(at+4<=n) {NzU off=matches[at];if(!off || off>at || off>65535) {at++;continue;}
        NzU len=0;while(at+len<n && input[at+len]==input[at+len-off])len++;
        if(len<4) {at++;continue;}
        if(ns>=16384)return 0;NzU ll=at-anchor;for(NzU j=anchor;j<at;j++)literals[nl++]=input[j];
        seq[ns++]=(NzSeq){ll,len-3,off+3};at+=len;anchor=at;
    }
    for(NzU j=anchor;j<n;j++)literals[nl++]=input[j];
    nz_le(out,0xfd2fb528,4);NzU frame;
    if(n<256) {out[4]=0x20;out[5]=(NzB)n;frame=6;}else {out[4]=0x60;nz_le(out+5,n-256,2);frame=7;}
    NzU pos=frame+3,h=nz_huffman(huffman,literals,nl),lh=nl<32?1:nl<4096?2:3;
    if(h && h+5<nl+lh) {
        NzU header=nl<1024 && h<1024?3:nl<16384 && h<16384?4:5;
        Nz64 v=2u|((Nz64)(header==3?1:header==4?2:3)<<2)|((Nz64)nl<<4)|((Nz64)h<<(header==3?14:header==4?18:22));
        for(NzU j=0;j<header;j++)out[pos++]=(NzB)(v>>(j*8));for(NzU j=0;j<h;j++)out[pos++]=huffman[j];
    }else {
        NzU v=lh==1?nl<<3:((lh==2?1u:3u)<<2)|(nl<<4);nz_le(out+pos,v,lh);pos+=lh;
        for(NzU j=0;j<nl;j++)out[pos++]=literals[j];
    }
    pos+=nz_sequences(out+pos,seq,ns);
    if(pos-frame-3>=n) {nz_le(out+frame,1u|(n<<3),3);for(NzU j=0;j<n;j++)out[frame+3+j]=input[j];return frame+3+n;}
    nz_le(out+frame,5u|((pos-frame-3)<<3),3);return pos;
}
#endif
