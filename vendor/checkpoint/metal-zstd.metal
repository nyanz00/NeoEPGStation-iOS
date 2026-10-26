/* BSD-3-Clause. iPhone Metal backend for the independently bounded Zstd
 * encoder, based on the official format and BSD-licensed Meta arithmetic. */
#include <metal_stdlib>
using namespace metal;
#include "metal-zstd-core.h"
#include "metal-zstd-parallel.h"
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
kernel void nz_encode_scalar(const device uchar *input [[buffer(0)]],const device uint *matches [[buffer(3)]],device NzSeq *seq [[buffer(4)]],device uchar *literals [[buffer(5)]],device uchar *huff [[buffer(6)]],device uchar *out [[buffer(7)]],device uint *sizes [[buffer(8)]],constant NzConfig &cfg [[buffer(9)]],uint block [[thread_position_in_grid]]) {
    if(block>=cfg.count)return;
    sizes[block]=nz_block(input+block*NZ_BLOCK,cfg.length[block],matches+block*NZ_BLOCK,seq+block*16384,literals+block*NZ_BLOCK,huff+block*NZ_BLOCK*2,out+block*NZ_SLOT);
}

kernel void nz_parse(const device uchar *input [[buffer(0)]],device NzSeq *parts [[buffer(2)]],const device uint *matches [[buffer(3)]],device uchar *lit [[buffer(6)]],constant NzConfig &cfg [[buffer(9)]],device NzWork *work [[buffer(10)]],uint i [[thread_position_in_grid]]) {
    uint b=i/16,p=i%16;if(b>=cfg.count)return;
    nzp_parse(input+b*NZ_BLOCK,cfg.length[b],matches+b*NZ_BLOCK,parts+b*16384+p*1024,lit+b*NZ_BLOCK*2+p*NZ_PART,work[b].part+p,p*NZ_PART);
}
kernel void nz_compact(const device NzSeq *parts [[buffer(2)]],device NzSeq *seq [[buffer(4)]],device uchar *lit [[buffer(5)]],const device uchar *partialLit [[buffer(6)]],constant NzConfig &cfg [[buffer(9)]],device NzWork *work [[buffer(10)]],uint b [[threadgroup_position_in_grid]],uint t [[thread_index_in_threadgroup]]) {
    if(b>=cfg.count)return;device NzWork *w=work+b;
    if(!t)nzp_compact_offsets(w);threadgroup_barrier(mem_flags::mem_device);
    for(uint p=0;p<16;p++) {NzPart a=w->part[p];
        for(uint j=t;j<a.ns;j+=128) {NzSeq s=parts[b*16384+p*1024+j];if(!j)s.ll+=a.carry;seq[b*16384+a.so+j]=s;}
        for(uint j=t;j<a.nl;j+=128)lit[b*NZ_BLOCK+a.lo+j]=partialLit[b*NZ_BLOCK*2+p*NZ_PART+j];
    }
    for(uint j=t;j<256;j+=128)w->hist[j]=0;
    for(uint j=t;j<192;j+=128)w->seqhist[j/64][j%64]=0;
}
kernel void nz_hist(const device NzSeq *seq [[buffer(4)]],const device uchar *lit [[buffer(5)]],constant NzConfig &cfg [[buffer(9)]],device NzWork *work [[buffer(10)]],uint group [[threadgroup_position_in_grid]],uint t [[thread_index_in_threadgroup]]) {
    uint b=group/16,part=group%16;if(b>=cfg.count)return;device NzWork *w=work+b;
    threadgroup atomic_uint hist[448];
    for(uint j=t;j<448;j+=128)atomic_store_explicit(hist+j,0,memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for(uint j=t;j<4096;j+=128) {uint p=part*4096+j;
        if(p<w->nl)atomic_fetch_add_explicit(hist+lit[b*NZ_BLOCK+p],1,memory_order_relaxed);
        if(p<w->ns) {NzSeq s=seq[b*16384+p];for(uint f=0;f<3;f++)atomic_fetch_add_explicit(hist+256+f*64+nzp_code(s,f),1,memory_order_relaxed);}
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for(uint j=t;j<448;j+=128) {uint count=atomic_load_explicit(hist+j,memory_order_relaxed);if(count) {
        device atomic_uint *dst=j<256?(device atomic_uint*)w->hist+j:(device atomic_uint*)w->seqhist[0]+j-256;
        atomic_fetch_add_explicit(dst,count,memory_order_relaxed);
    }}
}
kernel void nz_tree(constant NzConfig &cfg [[buffer(9)]],device NzWork *work [[buffer(10)]],uint b [[threadgroup_position_in_grid]],uint t [[thread_index_in_threadgroup]]) {
    if(b>=cfg.count)return;device NzWork *w=work+b;
    if(!t) {w->hvalid=0;w->hhsize=0;}if(w->nl<64)return;
    threadgroup atomic_uint maximum;threadgroup uint keys[256];
    for(uint floor=1;floor<=256;floor*=2) {
        for(uint j=t;j<256;j+=128) {uint count=max(w->hist[j],floor);w->count[j]=count;keys[j]=(count<<8)|j;}
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for(uint k=2;k<=256;k*=2)for(uint d=k/2;d;d/=2) {
            for(uint j=t;j<256;j+=128) {uint other=j^d;if(other>j) {
                uint a=keys[j],c=keys[other];
                if((a>c)==((j&k)==0)) {keys[j]=c;keys[other]=a;}
            }}threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        for(uint j=t;j<256;j+=128)w->sorted[j]=keys[j]&255;
        threadgroup_barrier(mem_flags::mem_device);
        if(!t) {nzp_tree(w);atomic_store_explicit(&maximum,0,memory_order_relaxed);}threadgroup_barrier(mem_flags::mem_device|mem_flags::mem_threadgroup);
        uint m=0;for(uint j=t;j<256;j+=128) {uint at=j,bits=0;while(at!=510) {bits++;at=w->parent[at];}w->length[j]=bits;m=max(m,bits);}
        atomic_fetch_max_explicit(&maximum,m,memory_order_relaxed);
        threadgroup_barrier(mem_flags::mem_device|mem_flags::mem_threadgroup);
        if(atomic_load_explicit(&maximum,memory_order_relaxed)<=11)break;
    }
    if(!t)nzp_canonical(w);
}
kernel void nz_tables(constant NzConfig &cfg [[buffer(9)]],device NzWork *work [[buffer(10)]],uint i [[thread_position_in_grid]]) {
    uint b=i/3,f=i%3;if(b>=cfg.count || !work[b].ns)return;
    uint hist[64],mode;NzFse table;for(uint j=0;j<64;j++)hist[j]=work[b].seqhist[f][j];
    work[b].tableSize[f]=nz_seqtable(work[b].tableHeader[f],&table,hist,work[b].ns,&mode);
    work[b].mode[f]=mode;work[b].fse[f].log=table.log;
    if(table.log)for(uint j=0;j<64;j++) {work[b].fse[f].state[j]=table.state[j];work[b].fse[f].bits[j]=table.bits[j];work[b].fse[f].find[j]=table.find[j];}
}
kernel void nz_chains(device uint *tokens [[buffer(3)]],const device NzSeq *seq [[buffer(4)]],constant NzConfig &cfg [[buffer(9)]],device NzWork *work [[buffer(10)]],uint i [[thread_position_in_grid]]) {
    uint b=i/3;if(b<cfg.count)nzp_chain(work+b,seq+b*16384,tokens+b*NZ_BLOCK,i%3);
}
kernel void nz_prefix(device uint *offsets [[buffer(2)]],device uint *tokens [[buffer(3)]],const device NzSeq *seq [[buffer(4)]],const device uchar *lit [[buffer(5)]],constant NzConfig &cfg [[buffer(9)]],device NzWork *work [[buffer(10)]],uint group [[threadgroup_position_in_grid]],uint t [[thread_index_in_threadgroup]]) {
    uint tile=group%128,r=(group/128)%5,b=group/(128*5);if(b>=cfg.count)return;
    device NzWork *w=work+b;uint quarter=(w->nl+3)/4,begin=r?(r-1)*quarter:0,end=r?min(begin+quarter,w->nl):w->ns;
    uint n=end>begin?end-begin:0,ordinal=tile*128+t;threadgroup uint scan[128];
    uint bits=0;if(ordinal<n) {uint p=end-1-ordinal;bits=r?(w->hvalid?w->length[lit[b*NZ_BLOCK+p]]:0):nzp_seqbits(seq[b*16384+p],tokens+b*NZ_BLOCK+p*4);}
    scan[t]=bits;threadgroup_barrier(mem_flags::mem_threadgroup);
    for(uint d=1;d<128;d*=2) {uint v=t>=d?scan[t-d]:0;threadgroup_barrier(mem_flags::mem_threadgroup);scan[t]+=v;threadgroup_barrier(mem_flags::mem_threadgroup);}
    if(ordinal<n) {uint p=end-1-ordinal;if(r)offsets[b*NZ_BLOCK+p]=scan[t]-bits;else tokens[b*NZ_BLOCK+p*4+3]=scan[t]-bits;}
    if(t==127)w->groupSum[r][tile]=scan[t];
}
kernel void nz_bases(device uint *sequenceBits [[buffer(1)]],device uint *huff [[buffer(6)]],constant NzConfig &cfg [[buffer(9)]],device NzWork *work [[buffer(10)]],uint group [[threadgroup_position_in_grid]],uint t [[thread_index_in_threadgroup]]) {
    uint r=group%5,b=group/5;if(b>=cfg.count)return;device NzWork *w=work+b;
    threadgroup uint scan[128];uint bits=w->groupSum[r][t];scan[t]=bits;threadgroup_barrier(mem_flags::mem_threadgroup);
    for(uint d=1;d<128;d*=2) {uint v=t>=d?scan[t-d]:0;threadgroup_barrier(mem_flags::mem_threadgroup);scan[t]+=v;threadgroup_barrier(mem_flags::mem_threadgroup);}
    w->groupBase[r][t]=scan[t]-bits;
    if(t==127) {w->total[r]=scan[t];uint tail=r || !w->ns?1:w->fse[0].log+w->fse[1].log+w->fse[2].log+1;w->bytes[r]=(scan[t]+tail+7)/8;}
    /* Match heads and partial literals are dead now. Reuse them as bitstreams. */
    if(!r)for(uint j=t;j<NZ_HASH;j+=128)sequenceBits[b*NZ_HASH+j]=0;
    else for(uint j=t;j<NZ_STREAM_SLOT/4;j+=128)huff[b*NZ_BLOCK/2+(r-1)*NZ_STREAM_SLOT/4+j]=0;
}
static void nzp_or(device uint *dst,uint at,uint value,uint bits) {
    if(!bits)return;value&=(1u<<bits)-1;uint word=at/32,shift=at%32;
    atomic_fetch_or_explicit((device atomic_uint*)dst+word,value<<shift,memory_order_relaxed);
    if(shift+bits>32)atomic_fetch_or_explicit((device atomic_uint*)dst+word+1,value>>(32-shift),memory_order_relaxed);
}
kernel void nz_pack(device uint *sequenceBits [[buffer(1)]],const device uint *offsets [[buffer(2)]],const device uint *tokens [[buffer(3)]],const device NzSeq *seq [[buffer(4)]],const device uchar *lit [[buffer(5)]],device uint *huff [[buffer(6)]],constant NzConfig &cfg [[buffer(9)]],device NzWork *work [[buffer(10)]],uint i [[thread_position_in_grid]]) {
    uint b=i/NZ_BLOCK,p=i%NZ_BLOCK;if(b>=cfg.count)return;device NzWork *w=work+b;
    device uint *sb=sequenceBits+b*NZ_HASH;
    if(p<w->ns) {uint reverse=w->ns-1-p;const device uint *token=tokens+b*NZ_BLOCK+p*4;uint at=token[3]+w->groupBase[0][reverse/128];
        for(uint k=0;k<3;k++) {uint f=2-k,v=token[f];nzp_or(sb,at,v,v>>16);at+=v>>16;}
        NzSeq s=seq[b*16384+p];uint l=nz_llbits[nz_llcode(s.ll)],m=nz_mlbits[nz_mlcode(s.ml)],o=nz_log(s.off);
        nzp_or(sb,at,s.ll,l);at+=l;nzp_or(sb,at,s.ml,m);at+=m;nzp_or(sb,at,s.off,o);
    }
    if(w->hvalid && p<w->nl) {uint quarter=(w->nl+3)/4,r=p/quarter,end=min((r+1)*quarter,w->nl),reverse=end-1-p;
        uint at=offsets[i]+w->groupBase[r+1][reverse/128],symbol=lit[i];nzp_or(huff+b*NZ_BLOCK/2+r*NZ_STREAM_SLOT/4,at,w->code[symbol],w->length[symbol]);
    }
    if(!p) {
        if(w->ns) {uint at=w->total[0];for(uint k=0;k<3;k++) {uint f=k==0?1:k==1?2:0;nzp_or(sb,at,w->state[f],w->fse[f].log);at+=w->fse[f].log;}nzp_or(sb,at,1,1);}
        if(w->hvalid)for(uint r=0;r<4;r++)nzp_or(huff+b*NZ_BLOCK/2+r*NZ_STREAM_SLOT/4,w->total[r+1],1,1);
    }
}
kernel void nz_assemble(const device uchar *input [[buffer(0)]],const device uchar *sequenceBits [[buffer(1)]],const device uchar *lit [[buffer(5)]],const device uchar *huff [[buffer(6)]],device uchar *out [[buffer(7)]],device uint *sizes [[buffer(8)]],constant NzConfig &cfg [[buffer(9)]],device NzWork *work [[buffer(10)]],uint b [[threadgroup_position_in_grid]],uint t [[thread_index_in_threadgroup]]) {
    if(b>=cfg.count)return;device NzWork *w=work+b;device uchar *dst=out+b*NZ_SLOT;uint n=cfg.length[b];
    if(!t) {nzp_layout(w,n,dst);sizes[b]=w->totalSize;}threadgroup_barrier(mem_flags::mem_device);
    if(w->raw) {for(uint j=t;j<n;j+=128)dst[w->frame+3+j]=input[b*NZ_BLOCK+j];return;}
    if(w->useHuff) {uint start=w->litHeader+w->hhsize+6;
        for(uint r=0;r<4;r++) {for(uint j=t;j<w->bytes[r+1];j+=128)dst[start+j]=huff[b*NZ_BLOCK*2+r*NZ_STREAM_SLOT+j];start+=w->bytes[r+1];}
    }else for(uint j=t;j<w->nl;j+=128)dst[w->litHeader+j]=lit[b*NZ_BLOCK+j];
    if(w->ns)for(uint j=t;j<w->bytes[0];j+=128)dst[w->headerEnd+j]=sequenceBits[b*NZ_HASH*4+j];
}
