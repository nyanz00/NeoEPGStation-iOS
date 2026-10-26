/* Test the shipping Metal host bridge and all four GPU passes, before the
 * application build. Exact bytes, mixed image geometry and tail values. */
#include "lscomp.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(void) {
    double setup=0;int e=neo_lscomp_begin(&setup);
    if(e==1009) {puts("{\"gpuUnavailable\":true,\"cases\":0}");return 0;}
    if(e)return e;
    int cases=0;
    for(unsigned word=1;word<=2;word++)for(unsigned pattern=0;pattern<4;pattern++)for(unsigned width=7;width<=128;width=width==7?17:width==17?128:129) {
        NeoRcompInput in[3]={{0}};NeoRcompOutput cpu[3]={{0}},gpu[3]={{0}};
        const unsigned words[3]={65,4097,65539};
        for(int j=0;j<3;j++) {
            size_t size=(size_t)words[j]*word;uint8_t *data=malloc(size);if(!data)return 2;uint32_t rng=0x12345678;
            for(unsigned k=0;k<words[j];k++) {
                rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;
                uint32_t v=pattern==0?0:pattern==1?0xffff:pattern==2?rng:(k*29)&1023;
                data[k*word]=(uint8_t)v;if(word==2)data[k*2+1]=(uint8_t)(v>>8);
            }
            in[j]=(NeoRcompInput){data,size,width,word};
        }
        e=neo_lscomp_cpu_pack(in,cpu,3);if(!e)e=neo_lscomp_gpu_pack(in,gpu,3);
        NeoRcompMetrics metrics;neo_lscomp_last_metrics(&metrics);
        if(!e && (metrics.dispatches!=4 || !metrics.staging_bytes || metrics.wait_ms<=0))e=3;
        for(int j=0;j<3;j++) {
            if(!e && (cpu[j].size!=gpu[j].size || memcmp(cpu[j].data,gpu[j].data,cpu[j].size)))e=4;
            uint8_t *out=malloc(in[j].size);if(!out)e=5;
            if(!e && (neo_lscomp_unpack(gpu[j].data,gpu[j].size,out,in[j].size) || memcmp(out,in[j].data,in[j].size)))e=6;
            free(out);free((void*)in[j].data);free(cpu[j].data);free(gpu[j].data);
        }
        if(e) {neo_lscomp_end();fprintf(stderr,"lsCOMP Metal mismatch: %d at word=%u pattern=%u width=%u\n",e,word,pattern,width);return e;}
        cases++;
    }
    neo_lscomp_end();printf("{\"gpuUnavailable\":false,\"cases\":%d,\"images\":%d,\"byteExact\":true,\"setupMs\":%.3f}\n",cases,cases*3,setup);return 0;
}
