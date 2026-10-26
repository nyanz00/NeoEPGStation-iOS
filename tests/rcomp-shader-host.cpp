/* Execute the unchanged integer kernel as C++ on the host, then use the
 * shipping private LZ4 decoder. This checks bytes/bounds, not GPU performance. */
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
extern "C" {
#include "rcomp.h"
}
using uchar=unsigned char;
using uint=unsigned int;
using ulong=unsigned long long;
using std::min;
#define constant const
#define device
#define thread
#define kernel
#include "rcomp-host-kernel.inc"
int main() {
    int cases=0;
    for(size_t n:{1u,4u,11u,12u,13u,65523u,65524u,65535u,65536u,65537u,131073u,1048577u}) {
        for(int pattern=0;pattern<4;pattern++) {
            size_t blocks=(n+NEO_RCOMP_BLOCK-1)/NEO_RCOMP_BLOCK;
            std::vector<uint8_t> input(blocks*NEO_RCOMP_BLOCK,0),slots(blocks*NEO_RCOMP_SLOT+64,0xa5),decoded(n);
            std::vector<uint32_t> sizes(blocks,0xffffffff),hashes(blocks*4096);
            uint32_t rng=0x12345678;
            for(size_t i=0;i<n;i++) {
                rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;
                input[i]=pattern==0?0:pattern==1?uint8_t(i%37):pattern==2?uint8_t(rng):uint8_t((i/11)%256);
            }
            Lz4Parameters p={(uint32_t)input.size(),NEO_RCOMP_BLOCK,NEO_RCOMP_SLOT,(uint32_t)blocks};
            for(uint32_t i=0;i<blocks;i++)rcomp_lz4_compress_blocks(input.data(),slots.data(),sizes.data(),hashes.data(),p,i);
            for(size_t i=blocks*NEO_RCOMP_SLOT;i<slots.size();i++)if(slots[i]!=0xa5)return 1;
            NeoRcompOutput packed={0};
            if(neo_rcomp_assemble(input.data(),n,slots.data(),sizes.data(),&packed))return 2;
            if(neo_rcomp_unpack(packed.data,packed.size,decoded.data(),n) || memcmp(input.data(),decoded.data(),n))return 3;
            if(!neo_rcomp_unpack(packed.data,packed.size-1,decoded.data(),n))return 4;
            free(packed.data);
            NeoRcompInput original={input.data(),n};packed={0};
            if(neo_rcomp_cpu_pack(&original,&packed,1) || neo_rcomp_unpack(packed.data,packed.size,decoded.data(),n) || memcmp(input.data(),decoded.data(),n))return 5;
            free(packed.data);cases++;
        }
    }
    printf("{\"cases\":%d,\"shaderBytesVerified\":true,\"gpuPerformanceMeasured\":false}\n",cases);
    return 0;
}
