/* Exact Metal integer analysis/emission on CPU, independent prefix oracle,
 * native CPU encoder and decoder. Actual GPU scans are verified in the app. */
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
extern "C" {
#include "lscomp.h"
}
using uchar=unsigned char;using uint=unsigned int;using std::max;
#define constant const
#define device
#define kernel
#include "lscomp-host-kernel.inc"
int main() {
    int cases=0;
    for(unsigned word:{1u,2u})for(unsigned n:{1u,7u,63u,64u,65u,511u,4097u,65539u})for(unsigned width:{3u,8u,17u,128u})for(unsigned pattern=0;pattern<4;pattern++) {
        std::vector<uint8_t> data(n*word),restored(n*word);uint32_t rng=0x12345678;
        for(unsigned i=0;i<n;i++) {
            rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;
            uint32_t v=pattern==0?0:pattern==1?0xffff:pattern==2?rng:(i*29)&1023;
            data[i*word]=(uint8_t)v;if(word==2)data[i*2+1]=(uint8_t)(v>>8);
        }
        NeoRcompInput in={data.data(),data.size(),width,word};NeoLsImage geom;
        if(neo_lscomp_geometry(&in,&geom))return 1;
        NeoRcompOutput cpu={0},emulated={0};if(neo_lscomp_cpu_pack(&in,&cpu,1))return 2;
        LsConfig cfg={};static_assert(sizeof(cfg.image[0])==sizeof(geom));memcpy(&cfg.image[0],&geom,sizeof(geom));
        cfg.images=1;cfg.tiles=geom.tiles;cfg.groups=(cfg.tiles+255)/256;
        std::vector<uint8_t> widths(cfg.tiles),payload(cfg.tiles*128+64,0xa5);
        std::vector<uint32_t> offsets(cfg.tiles),bases(cfg.groups);uint32_t sum=0,local=0;
        for(unsigned t=0;t<cfg.tiles;t++)neo_ls_analyse(data.data(),widths.data(),cfg,t);
        for(unsigned t=0;t<cfg.tiles;t++) {
            if(t%256==0) {bases[t/256]=sum;local=0;}
            offsets[t]=local;local+=widths[t]*8;sum+=widths[t]*8;
        }
        for(unsigned t=0;t<cfg.tiles;t++)neo_ls_emit(data.data(),widths.data(),offsets.data(),bases.data(),payload.data(),cfg,t);
        for(unsigned t=sum;t<payload.size();t++)if(payload[t]!=0xa5)return 3;
        if(neo_lscomp_assemble(&geom,widths.data(),payload.data(),sum,&emulated))return 4;
        if(cpu.size!=emulated.size || memcmp(cpu.data,emulated.data,cpu.size))return 5;
        if(neo_lscomp_unpack(emulated.data,emulated.size,restored.data(),data.size()) || data!=restored)return 6;
        if(!neo_lscomp_unpack(emulated.data,emulated.size-1,restored.data(),data.size()))return 7;
        free(cpu.data);free(emulated.data);cases++;
    }
    // Published bit-plane ordering: alternating 0/1 tile becomes eight 0x55 bytes.
    uint8_t tile[64];for(int i=0;i<64;i++)tile[i]=i&1;NeoRcompInput in={tile,64,8,1};NeoRcompOutput out={0};
    if(neo_lscomp_cpu_pack(&in,&out,1) || out.size!=36 || out.data[24]!=1)return 8;
    for(int i=28;i<36;i++)if(out.data[i]!=0x55)return 9;
    free(out.data);printf("{\"cases\":%d,\"goldenBitplanes\":true,\"byteExact\":true,\"gpuScansMeasured\":false}\n",cases);return 0;
}
