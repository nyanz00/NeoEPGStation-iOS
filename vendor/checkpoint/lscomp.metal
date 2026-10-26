/* Copyright (c) 2025 UChicago Argonne and University of Iowa.
 * Lossless-only lsCOMP adaptation. See vendor/lscomp/LICENSE.
 * New staged scans replace CUDA's global spin waits. */
#include <metal_stdlib>
using namespace metal;
struct LsImage {uint raw_bytes,row_width,word_bytes,first_byte,first_tile,tile_columns,tile_rows,tiles;};
struct LsConfig {LsImage image[8];uint images,tiles,groups;};
inline LsImage image_for(constant LsConfig &cfg,uint tile) {
    for(uint j=0;j<cfg.images;j++)if(tile>=cfg.image[j].first_tile && tile<cfg.image[j].first_tile+cfg.image[j].tiles)return cfg.image[j];
    return cfg.image[0];
}
inline uint load_sample(const device uchar *input,LsImage im,uint tile,uint k) {
    uint local=tile-im.first_tile,x=(local%im.tile_columns)*8+k%8,y=(local/im.tile_columns)*8+k/8;
    uint index=y*im.row_width+x;
    if(x>=im.row_width || index>=im.raw_bytes/im.word_bytes)return 0;
    uint p=im.first_byte+index*im.word_bytes;
    return uint(input[p])|(im.word_bytes==2?uint(input[p+1])<<8:0);
}
kernel void neo_ls_analyse(const device uchar *input [[buffer(0)]],device uchar *widths [[buffer(1)]],
    constant LsConfig &cfg [[buffer(6)]],uint tile [[thread_position_in_grid]]) {
    if(tile>=cfg.tiles)return;LsImage im=image_for(cfg,tile);uint maximum=0;
    for(uint k=0;k<64;k++)maximum=max(maximum,load_sample(input,im,tile,k));
    uint bits=0;while(maximum) {bits++;maximum>>=1;}widths[tile]=uchar(bits);
}
kernel void neo_ls_scan(const device uchar *widths [[buffer(1)]],device uint *offsets [[buffer(2)]],
    device uint *groups [[buffer(3)]],constant LsConfig &cfg [[buffer(6)]],
    uint lane [[thread_position_in_threadgroup]],uint group [[threadgroup_position_in_grid]]) {
    threadgroup uint scan[256];uint tile=group*256+lane,own=tile<cfg.tiles?uint(widths[tile])*8:0;
    scan[lane]=own;threadgroup_barrier(mem_flags::mem_threadgroup);
    for(uint step=1;step<256;step<<=1) {
        uint add=lane>=step?scan[lane-step]:0;threadgroup_barrier(mem_flags::mem_threadgroup);
        scan[lane]+=add;threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if(tile<cfg.tiles)offsets[tile]=scan[lane]-own;
    if(lane==255)groups[group]=scan[255];
}
kernel void neo_ls_bases(const device uint *groups [[buffer(3)]],device uint *bases [[buffer(4)]],
    constant LsConfig &cfg [[buffer(6)]],uint index [[thread_position_in_grid]]) {
    if(index)return;uint sum=0;
    for(uint j=0;j<cfg.groups;j++) {bases[j]=sum;sum+=groups[j];}
}
kernel void neo_ls_emit(const device uchar *input [[buffer(0)]],const device uchar *widths [[buffer(1)]],
    const device uint *offsets [[buffer(2)]],const device uint *bases [[buffer(4)]],device uchar *output [[buffer(5)]],
    constant LsConfig &cfg [[buffer(6)]],uint tile [[thread_position_in_grid]]) {
    if(tile>=cfg.tiles)return;LsImage im=image_for(cfg,tile);uint values[64];
    for(uint k=0;k<64;k++)values[k]=load_sample(input,im,tile,k);
    uint begin=offsets[tile]+bases[tile/256];
    for(uint bit=0;bit<widths[tile];bit++)for(uint lane=0;lane<8;lane++) {
        uint byte=0;for(uint k=0;k<8;k++)byte|=((values[lane*8+k]>>bit)&1u)<<(7-k);
        output[begin+bit*8+lane]=uchar(byte);
    }
}
