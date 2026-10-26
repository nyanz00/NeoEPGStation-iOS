/* Same shipping Metal bridge, standard CPU decoder, all allocation bytes. */
#include "rcomp.h"
#include "neo_compression_namespace.h"
#include "zstd.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "metal-zstd-input-test.h"
#ifdef NEO_MZSTD_NATIVE_DEBUG
void neo_mzstd_debug_last(void);
#endif
static int prepared_images(double *cpuMs,double *gpuMs) {
    const unsigned widths[]={1,7,31,1440,1920};
    for(unsigned word=1;word<=2;word++)for(unsigned k=0;k<5;k++) {
        NeoRcompGeometry g;size_t n=input_fixture(&g,widths[k],k<3?9:1080,word);
        uint8_t *raw=malloc(n),*expected=malloc(n),*decoded=malloc(n);if(!raw || !expected || !decoded)return 2;
        unsigned rng=0x77712345;for(size_t j=0;j<n;j++) {rng=rng*1664525u+1013904223u;raw[j]=(uint8_t)(rng>>24);}
        memcpy(expected,raw,n);input_reference(expected,&g);NeoRcompInput in={raw,n,widths[k],word,&g};
        for(int mode=0;mode<2;mode++) {
            neo_mzstd_preprocessing_control(mode);NeoRcompOutput out={0};struct timespec a,z;clock_gettime(CLOCK_MONOTONIC,&a);
            int e=neo_mzstd_gpu_pack(&in,&out,1);clock_gettime(CLOCK_MONOTONIC,&z);NeoRcompMetrics m;neo_mzstd_last_metrics(&m);
            if(!e) {size_t got=ZSTD_decompress(decoded,n,out.data,out.size);if(ZSTD_isError(got) || got!=n || memcmp(expected,decoded,n))e=5;}
            if(!e && (m.dispatches!=m.batch_count*(mode?13:12) || m.staging_bytes>32*1024*1024 || m.input_bytes!=n || m.output_bytes!=out.size || m.wait_count!=m.batch_count || m.max_in_flight!=(m.batch_count>1?2:1)))e=6;
            if(word==2 && k==4) {double ms=(z.tv_sec-a.tv_sec)*1000.+(z.tv_nsec-a.tv_nsec)/1e6;if(mode)*gpuMs=ms;else *cpuMs=ms;}
            free(out.data);if(e) {fprintf(stderr,"prepared image failed word=%u width=%u mode=%d error=%d\n",word,widths[k],mode,e);return e;}
        }
        free(raw);free(expected);free(decoded);
    }
    neo_mzstd_preprocessing_control(0);return 0;
}
static double wall_ms(void) {struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1000.+t.tv_nsec/1e6;}
static int speed_control(double *scalar,double *parallel,double *scalarGPU,double *parallelGPU,double *ratio,double *stages,int *timed) {
    size_t n=2*1024*1024;uint8_t *data=malloc(n),*decoded=malloc(n);if(!data || !decoded)return 2;
    unsigned rng=0x12345678;for(size_t p=0;p<n;p++) {rng=rng*1664525u+1013904223u;data[p]=p%65536<32768?(uint8_t)((rng>>27)&15):(uint8_t)(p/32);}
    NeoRcompInput in={data,n,0,0};double sizes[2];
    for(int mode=0;mode<2;mode++) {
        double elapsedSamples[3],gpuSamples[3];
        for(int repeat=0;repeat<4;repeat++) {
        neo_mzstd_scalar_control(mode==0?2:0);NeoRcompOutput out={0};double start=wall_ms();int e=neo_mzstd_gpu_pack(&in,&out,1);double elapsed=wall_ms()-start;
        NeoRcompMetrics m;neo_mzstd_last_metrics(&m);
        if(!e) {size_t got=ZSTD_decompress(decoded,n,out.data,out.size);if(ZSTD_isError(got) || got!=n || memcmp(data,decoded,n))e=5;}
        sizes[mode]=(double)out.size;
        if(repeat) {elapsedSamples[repeat-1]=elapsed;gpuSamples[repeat-1]=m.gpu_ms;}
        if(mode) {*timed=m.stage_timing_available;for(int j=0;j<8;j++)stages[j]=m.stage_ms[j];}
        free(out.data);if(e) {free(data);free(decoded);neo_mzstd_scalar_control(0);return e;}
        }
        for(int a=0;a<3;a++)for(int b=a+1;b<3;b++) {if(elapsedSamples[b]<elapsedSamples[a]) {double v=elapsedSamples[a];elapsedSamples[a]=elapsedSamples[b];elapsedSamples[b]=v;}if(gpuSamples[b]<gpuSamples[a]) {double v=gpuSamples[a];gpuSamples[a]=gpuSamples[b];gpuSamples[b]=v;}}
        if(!mode) {*scalar=elapsedSamples[1];*scalarGPU=gpuSamples[1];}else {*parallel=elapsedSamples[1];*parallelGPU=gpuSamples[1];}
    }
    neo_mzstd_scalar_control(0);*ratio=sizes[1]/sizes[0];free(data);free(decoded);return 0;
}
int main(void) {
    int inputError=input_cpu_test();if(inputError)return inputError;
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
        if(!e && (metrics.dispatches!=12*metrics.batch_count || !metrics.staging_bytes || metrics.staging_bytes>32*1024*1024 || metrics.wait_ms<=0 || metrics.input_bytes!=in[0].size+in[1].size+in[2].size))e=3;
        for(unsigned j=0;j<3;j++) {
            uint8_t *decoded=malloc(in[j].size);if(!decoded)e=4;
            if(!e) {size_t n=ZSTD_decompress(decoded,in[j].size,out[j].data,out[j].size);
                if(ZSTD_isError(n) || n!=in[j].size || memcmp(decoded,in[j].data,n)) {fprintf(stderr,"Zstd decode: %s image=%u\n",ZSTD_getErrorName(n),j);
#ifdef NEO_MZSTD_NATIVE_DEBUG
                    neo_mzstd_debug_last();
#endif
                    e=5;}
                if(out[j].size<in[j].size)compressed++;
            }
            free(decoded);free((void*)in[j].data);free(out[j].data);
        }
        if(e) {neo_mzstd_end();fprintf(stderr,"Metal Zstd failed: %d pattern=%u size=%zu\n",e,pattern,sizes[k]);return e;}cases++;
    }
    double scalar=0,parallel=0,scalarGPU=0,parallelGPU=0,ratio=0,stages[8],cpuPrep=0,gpuPrep=0;int timed=0;
    e=speed_control(&scalar,&parallel,&scalarGPU,&parallelGPU,&ratio,stages,&timed);
    if(!e)e=prepared_images(&cpuPrep,&gpuPrep);neo_mzstd_end();if(e)return e;
    printf("{\"gpuUnavailable\":false,\"cases\":%u,\"images\":%u,\"compressedImages\":%u,\"byteExact\":true,\"setupMs\":%.3f,\"legacy277WallMs\":%.3f,\"parallelWallMs\":%.3f,\"legacy277GpuMs\":%.3f,\"parallelGpuMs\":%.3f,\"parallelToLegacy277Size\":%.6f,\"stageTimedBatches\":%d,\"preprocessingCases\":10,\"preprocessingImages\":20,\"cpuDirectPreparationWallMs\":%.3f,\"gpuPreparationWallMs\":%.3f,\"parallelStageMs\":[",cases,cases*3,compressed,setup,scalar,parallel,scalarGPU,parallelGPU,ratio,timed,cpuPrep,gpuPrep);
    for(int j=0;j<8;j++)printf("%s%.6f",j?",":"",stages[j]);puts("]}");return 0;
}
