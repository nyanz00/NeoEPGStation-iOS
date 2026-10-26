/* BSD-3-Clause. iPhone Metal backend for the independently bounded Zstd
 * encoder, based on the official format and BSD-licensed Meta arithmetic. */
#include <metal_stdlib>
using namespace metal;
#include "metal-zstd-core.h"
struct NzConfig {uint count,length[16];};
kernel void nz_clear(device atomic_uint *head [[buffer(1)]],constant NzConfig &cfg [[buffer(9)]],uint i [[thread_position_in_grid]]) {
    if(i<cfg.count*NZ_HASH)atomic_store_explicit(head+i,~0u,memory_order_relaxed);
}
kernel void nz_insert(const device uchar *input [[buffer(0)]],device atomic_uint *head [[buffer(1)]],device uint *previous [[buffer(2)]],constant NzConfig &cfg [[buffer(9)]],uint i [[thread_position_in_grid]]) {
    uint block=i/NZ_BLOCK,p=i%NZ_BLOCK;if(block>=cfg.count)return;previous[i]=~0u;if(p+4>cfg.length[block])return;
    const device uchar *src=input+block*NZ_BLOCK;
    if(p && (p&31) && src[p]==src[p-1] && src[p+1]==src[p] && src[p+2]==src[p] && src[p+3]==src[p])return;
    previous[i]=atomic_exchange_explicit(head+block*NZ_HASH+nz_hash(src+p),p,memory_order_relaxed);
}
kernel void nz_match(const device uchar *input [[buffer(0)]],const device uint *previous [[buffer(2)]],device uint *matches [[buffer(3)]],constant NzConfig &cfg [[buffer(9)]],uint i [[thread_position_in_grid]]) {
    uint block=i/NZ_BLOCK,p=i%NZ_BLOCK;if(block>=cfg.count)return;matches[i]=0;if(p+4>cfg.length[block])return;
    const device uchar *src=input+block*NZ_BLOCK;uint best=~0u;
    for(uint off=1;off<=32 && off<=p;off*=2)if(src[p]==src[p-off] && src[p+1]==src[p+1-off] && src[p+2]==src[p+2-off] && src[p+3]==src[p+3-off]) {best=off;break;}
    uint c=previous[i];for(uint tries=0;best!=1 && c!=~0u && tries<32;tries++) {
        if(c>=cfg.length[block] || c+4>cfg.length[block])break;
        if(c<p && p-c<best && src[p]==src[c] && src[p+1]==src[c+1] && src[p+2]==src[c+2] && src[p+3]==src[c+3])best=p-c;
        c=previous[block*NZ_BLOCK+c];
    }
    if(best!=~0u)matches[i]=best;
}
kernel void nz_encode(const device uchar *input [[buffer(0)]],const device uint *matches [[buffer(3)]],device NzSeq *seq [[buffer(4)]],device uchar *literals [[buffer(5)]],device uchar *huff [[buffer(6)]],device uchar *out [[buffer(7)]],device uint *sizes [[buffer(8)]],constant NzConfig &cfg [[buffer(9)]],uint block [[thread_position_in_grid]]) {
    if(block>=cfg.count)return;
    sizes[block]=nz_block(input+block*NZ_BLOCK,cfg.length[block],matches+block*NZ_BLOCK,seq+block*16384,literals+block*NZ_BLOCK,huff+block*NZ_BLOCK*2,out+block*NZ_SLOT);
}
