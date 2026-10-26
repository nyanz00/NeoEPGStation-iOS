/* Same shipping Metal bridge, standard CPU decoder, all allocation bytes. */
#include "rcomp.h"
#include "neo_compression_namespace.h"
#include "zstd.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(void) {
    double setup=0;int e=neo_mzstd_begin(&setup);if(e==1009) {puts("{\"gpuUnavailable\":true,\"cases\":0}");return 0;}if(e)return e;
    unsigned cases=0,compressed=0;const size_t sizes[3]={1,255,65536+137};
    for(unsigned pattern=0;pattern<8;pattern++)for(unsigned k=0;k<3;k++) {
        NeoRcompInput in[3]={{0}};NeoRcompOutput out[3]={{0}};
        for(unsigned j=0;j<3;j++) {
            size_t n=j==0?sizes[k]:j==1?sizes[k]+9:sizes[k]*2+7;uint8_t *data=malloc(n);if(!data)return 2;
            unsigned rng=0x12345678;
            for(size_t p=0;p<n;p++) {rng=rng*1664525u+1013904223u;data[p]=pattern==0?0:pattern==1?255:pattern==2?(uint8_t)(p%37):pattern==3?(uint8_t)(rng>>24):pattern==4?(uint8_t)((rng>>28)&7):pattern==5?(uint8_t)p:pattern==6?(p%11?0:(uint8_t)(rng>>24)):(uint8_t)(p/32);}
            in[j]=(NeoRcompInput){data,n,0,0};
        }
        e=neo_mzstd_gpu_pack(in,out,3);NeoRcompMetrics metrics;neo_mzstd_last_metrics(&metrics);
        if(!e && (metrics.dispatches<4 || metrics.dispatches%4 || !metrics.staging_bytes || metrics.staging_bytes>32*1024*1024 || metrics.wait_ms<=0))e=3;
        for(unsigned j=0;j<3;j++) {
            uint8_t *decoded=malloc(in[j].size);if(!decoded)e=4;
            if(!e) {size_t n=ZSTD_decompress(decoded,in[j].size,out[j].data,out[j].size);
                if(ZSTD_isError(n) || n!=in[j].size || memcmp(decoded,in[j].data,n)) {fprintf(stderr,"Zstd decode: %s\n",ZSTD_getErrorName(n));e=5;}
                if(out[j].size<in[j].size)compressed++;
            }
            free(decoded);free((void*)in[j].data);free(out[j].data);
        }
        if(e) {neo_mzstd_end();fprintf(stderr,"Metal Zstd failed: %d pattern=%u size=%zu\n",e,pattern,sizes[k]);return e;}cases++;
    }
    neo_mzstd_end();printf("{\"gpuUnavailable\":false,\"cases\":%u,\"images\":%u,\"compressedImages\":%u,\"byteExact\":true,\"setupMs\":%.3f}\n",cases,cases*3,compressed,setup);return 0;
}
