/* BSD-3-Clause. iPhone Metal Zstandard diagnostic backend. CPU handles only
 * input/output transfer here; all match/parse/entropy/frame work is in Metal. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "rcomp.h"
#include "metal-zstd-shader.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>
#define MZ_BATCH 16u
#define MZ_BLOCK 65536u
#define MZ_HASH 32768u
#define MZ_SLOT (MZ_BLOCK+1024u)
typedef struct MzConfig {uint32_t count,length[MZ_BATCH];} MzConfig;
@interface NeoMetalZstdSession : NSObject {
@public
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLComputePipelineState> pipeline[4];
    id<MTLBuffer> buffers[9];
    NeoRcompMetrics metrics;
}
@end
@implementation NeoMetalZstdSession
@end
static _Thread_local void *current;
static double mz_ms(void) {struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1000.0+t.tv_nsec/1e6;}
int neo_mzstd_begin(double *setup) {
    if(setup)*setup=0;if(current)return 1001;
    @autoreleasepool {
        double began=mz_ms();NeoMetalZstdSession *s=[NeoMetalZstdSession new];s->device=MTLCreateSystemDefaultDevice();if(!s->device)return 1009;
        MTLCompileOptions *options=[MTLCompileOptions new];options.fastMathEnabled=NO;NSError *error=nil;
        id<MTLLibrary> lib=[s->device newLibraryWithSource:[NSString stringWithUTF8String:neo_mzstd_shader_source] options:options error:&error];
        if(!lib) {NSLog(@"Metal Zstandard shader: %@",error.localizedDescription);return 1011;}
        const char *names[4]={"nz_clear","nz_insert","nz_match","nz_encode"};
        for(unsigned j=0;j<4;j++) {
            id<MTLFunction> f=[lib newFunctionWithName:[NSString stringWithUTF8String:names[j]]];if(!f)return 1011;
            s->pipeline[j]=[s->device newComputePipelineStateWithFunction:f error:&error];if(!s->pipeline[j])return 1011;
        }
        s->queue=[s->device newCommandQueue];if(!s->queue)return 1011;
        const size_t lens[9]={MZ_BATCH*MZ_BLOCK,MZ_BATCH*MZ_HASH*4,MZ_BATCH*MZ_BLOCK*4,MZ_BATCH*MZ_BLOCK*4,
            MZ_BATCH*16384*12,MZ_BATCH*MZ_BLOCK,MZ_BATCH*MZ_BLOCK*2,MZ_BATCH*MZ_SLOT,MZ_BATCH*4};
        size_t total=0;for(unsigned j=0;j<9;j++) {total+=lens[j];if(lens[j]>s->device.maxBufferLength)return 1005;
            s->buffers[j]=[s->device newBufferWithLength:lens[j] options:MTLResourceStorageModeShared];if(!s->buffers[j])return 1005;}
        if(total>32*1024*1024)return 1005;s->metrics.staging_bytes=total;
        current=(void*)CFBridgingRetain(s);if(setup)*setup=mz_ms()-began;return 0;
    }
}
void neo_mzstd_end(void) {@autoreleasepool {if(current) {id released=CFBridgingRelease(current);current=NULL;(void)released;}}}
void neo_mzstd_last_metrics(NeoRcompMetrics *out) {memset(out,0,sizeof(*out));if(current) {NeoMetalZstdSession *s=(__bridge id)current;*out=s->metrics;}}
int neo_mzstd_gpu_pack(const NeoRcompInput *input,NeoRcompOutput *out,unsigned images) {
    if(!current)return 1009;if(!input || !out || !images || images>8)return 1001;
    @autoreleasepool {
        NeoMetalZstdSession *s=(__bridge id)current;uint64_t staging=s->metrics.staging_bytes;memset(&s->metrics,0,sizeof(s->metrics));s->metrics.staging_bytes=staging;
        size_t total=0;for(unsigned i=0;i<images;i++) {if(!input[i].data || !input[i].size || input[i].size>48*1024*1024)return 1001;total+=input[i].size;}
        if(total>48*1024*1024)return 1005;
        for(unsigned i=0;i<images;i++) {size_t cap=input[i].size+((input[i].size+MZ_BLOCK-1)/MZ_BLOCK)*1024;
            out[i].data=malloc(cap);out[i].size=0;if(!out[i].data)return 1005;}
        unsigned image=0;size_t offset=0;
        while(image<images) {
            MzConfig cfg={0};unsigned owners[MZ_BATCH];
            while(cfg.count<MZ_BATCH && image<images) {
                size_t size=MIN((size_t)MZ_BLOCK,input[image].size-offset);unsigned b=cfg.count++;
                cfg.length[b]=(uint32_t)size;owners[b]=image;memcpy((uint8_t*)s->buffers[0].contents+(size_t)b*MZ_BLOCK,input[image].data+offset,size);
                offset+=size;if(offset==input[image].size) {image++;offset=0;}
            }
            id<MTLCommandBuffer> command=[s->queue commandBuffer];if(!command)return 1011;
            for(unsigned pass=0;pass<4;pass++) {
                id<MTLComputeCommandEncoder> enc=[command computeCommandEncoder];if(!enc)return 1011;
                [enc setComputePipelineState:s->pipeline[pass]];
                for(unsigned j=0;j<9;j++)[enc setBuffer:s->buffers[j] offset:0 atIndex:j];[enc setBytes:&cfg length:sizeof(cfg) atIndex:9];
                NSUInteger n=pass==0?cfg.count*MZ_HASH:pass==3?cfg.count:cfg.count*MZ_BLOCK;
                /* Entropy blocks are independent: one group per block lets a
                 * small iPhone batch occupy multiple GPU cores. */
                NSUInteger width=pass==3?1:MIN(n,MIN(s->pipeline[pass].threadExecutionWidth,s->pipeline[pass].maxTotalThreadsPerThreadgroup));
                if(!width)return 1011;[enc dispatchThreads:MTLSizeMake(n,1,1) threadsPerThreadgroup:MTLSizeMake(width,1,1)];[enc endEncoding];
            }
            double began=mz_ms();[command commit];[command waitUntilCompleted];s->metrics.wait_ms+=mz_ms()-began;s->metrics.dispatches+=4;
            if(command.status!=MTLCommandBufferStatusCompleted)return 1011;
            if(command.GPUStartTime>0 && command.GPUEndTime>=command.GPUStartTime)s->metrics.gpu_ms+=(command.GPUEndTime-command.GPUStartTime)*1000;
            const uint32_t *sizes=s->buffers[8].contents;
            for(unsigned b=0;b<cfg.count;b++) {size_t n=sizes[b];if(!n || n>MZ_SLOT)return 1010;unsigned i=owners[b];
                size_t cap=input[i].size+((input[i].size+MZ_BLOCK-1)/MZ_BLOCK)*1024;if(out[i].size+n>cap)return 1010;
                memcpy(out[i].data+out[i].size,(const uint8_t*)s->buffers[7].contents+(size_t)b*MZ_SLOT,n);out[i].size+=n;
            }
        }
        for(unsigned i=0;i<images;i++) {void *small=realloc(out[i].data,out[i].size);if(small)out[i].data=small;}
        return 0;
    }
}
