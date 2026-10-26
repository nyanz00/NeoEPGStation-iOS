/* iOS diagnostic host bridge for the unmodified rcomp-metal 0.4.0 kernel.
 * Own bridge: BSD-2-Clause. Upstream shader: Apache-2.0 option. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "rcomp.h"
#include "rcomp-shader.h"
#include <string.h>
#include <stdlib.h>
#include <time.h>

@interface NeoCheckpointRcompSession : NSObject {
@public
    id<MTLDevice> device;
    id<MTLComputePipelineState> pipeline;
    id<MTLCommandQueue> queue;
    id<MTLBuffer> input,output,sizes,hashes;
    NeoRcompMetrics metrics;
}
@end
@implementation NeoCheckpointRcompSession
@end
static _Thread_local void *neo_rcomp_current;
static double milliseconds(void) {
    struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1000.0+t.tv_nsec/1e6;
}
int neo_rcomp_begin(double *setup_ms) {
    if(setup_ms)*setup_ms=0;
    if(neo_rcomp_current)return 1001;
    @autoreleasepool {
        double began=milliseconds();
        NeoCheckpointRcompSession *s=[NeoCheckpointRcompSession new];s->device=MTLCreateSystemDefaultDevice();
        if(!s->device)return 1009;
        NSError *error=nil;
        MTLCompileOptions *options=[MTLCompileOptions new];options.fastMathEnabled=NO;
        id<MTLLibrary> library=[s->device newLibraryWithSource:[NSString stringWithUTF8String:neo_rcomp_shader_source] options:options error:&error];
        if(!library)return 1011;
        id<MTLFunction> function=[library newFunctionWithName:@"rcomp_lz4_compress_blocks"];
        if(!function)return 1011;
        s->pipeline=[s->device newComputePipelineStateWithFunction:function error:&error];
        s->queue=[s->device newCommandQueue];if(!s->pipeline || !s->queue)return 1011;
        neo_rcomp_current=(void*)CFBridgingRetain(s);
        if(setup_ms)*setup_ms=milliseconds()-began;return 0;
    }
}
void neo_rcomp_end(void) {
    @autoreleasepool {
        if(neo_rcomp_current) {
            id released=CFBridgingRelease(neo_rcomp_current);neo_rcomp_current=NULL;(void)released;
        }
    }
}
void neo_rcomp_last_metrics(NeoRcompMetrics *out) {
    memset(out,0,sizeof(*out));
    if(neo_rcomp_current) {NeoCheckpointRcompSession *s=(__bridge id)neo_rcomp_current;*out=s->metrics;}
}
static BOOL ensure_buffer(id<MTLDevice> device,id<MTLBuffer> __strong *buffer,size_t size) {
    if(*buffer && (*buffer).length>=size)return YES;
    *buffer=[device newBufferWithLength:size options:MTLResourceStorageModeShared];return *buffer!=nil;
}
int neo_rcomp_gpu_pack(const NeoRcompInput *in,NeoRcompOutput *out,unsigned count) {
    if(!neo_rcomp_current)return 1009;
    if(!in || !out || !count || count>8)return 1001;
    @autoreleasepool {
        NeoCheckpointRcompSession *s=(__bridge id)neo_rcomp_current;memset(&s->metrics,0,sizeof(s->metrics));
        size_t first[8]={0},blocks[8]={0},n=0;
        for(unsigned j=0;j<count;j++) {
            if(!in[j].data || !in[j].size || in[j].size>48*1024*1024)return 1001;
            blocks[j]=(in[j].size+NEO_RCOMP_BLOCK-1)/NEO_RCOMP_BLOCK;first[j]=n;n+=blocks[j];
        }
        size_t input_bytes=n*NEO_RCOMP_BLOCK,output_bytes=n*NEO_RCOMP_SLOT;
        size_t sizes_bytes=n*sizeof(uint32_t),hash_bytes=n*4096*sizeof(uint32_t);
        if(input_bytes>48*1024*1024 || input_bytes+output_bytes+sizes_bytes+hash_bytes>128*1024*1024)return 1005;
        size_t lengths[4]={input_bytes,output_bytes,sizes_bytes,hash_bytes};
        for(int j=0;j<4;j++)if(lengths[j]>s->device.maxBufferLength)return 1005;
        if(!ensure_buffer(s->device,&s->input,input_bytes) || !ensure_buffer(s->device,&s->output,output_bytes) ||
           !ensure_buffer(s->device,&s->sizes,sizes_bytes) || !ensure_buffer(s->device,&s->hashes,hash_bytes))return 1005;
        s->metrics.staging_bytes=s->input.length+s->output.length+s->sizes.length+s->hashes.length;
        uint8_t *mapped=s->input.contents;
        for(unsigned j=0;j<count;j++) {
            memcpy(mapped+first[j]*NEO_RCOMP_BLOCK,in[j].data,in[j].size);
            memset(mapped+first[j]*NEO_RCOMP_BLOCK+in[j].size,0,blocks[j]*NEO_RCOMP_BLOCK-in[j].size);
        }
        struct {uint32_t total_size,block_size,output_slot_size,block_count;} params={
            (uint32_t)input_bytes,NEO_RCOMP_BLOCK,NEO_RCOMP_SLOT,(uint32_t)n};
        id<MTLCommandBuffer> command=[s->queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];if(!command || !encoder)return 1011;
        [encoder setComputePipelineState:s->pipeline];
        [encoder setBuffer:s->input offset:0 atIndex:0];[encoder setBuffer:s->output offset:0 atIndex:1];
        [encoder setBuffer:s->sizes offset:0 atIndex:2];[encoder setBuffer:s->hashes offset:0 atIndex:3];
        [encoder setBytes:&params length:sizeof(params) atIndex:4];
        NSUInteger width=MIN(n,MIN(s->pipeline.threadExecutionWidth,s->pipeline.maxTotalThreadsPerThreadgroup));
        if(!width)return 1011;
        [encoder dispatchThreads:MTLSizeMake(n,1,1) threadsPerThreadgroup:MTLSizeMake(width,1,1)];
        [encoder endEncoding];double began=milliseconds();[command commit];[command waitUntilCompleted];
        s->metrics.wait_ms=milliseconds()-began;s->metrics.dispatches=1;
        if(command.status!=MTLCommandBufferStatusCompleted)return 1011;
        if(command.GPUEndTime>=command.GPUStartTime && command.GPUStartTime>0)
            s->metrics.gpu_ms=(command.GPUEndTime-command.GPUStartTime)*1000;
        const uint32_t *lengths_out=s->sizes.contents;
        for(unsigned j=0;j<count;j++) {
            int e=neo_rcomp_assemble(mapped+first[j]*NEO_RCOMP_BLOCK,in[j].size,
                (const uint8_t*)s->output.contents+first[j]*NEO_RCOMP_SLOT,lengths_out+first[j],&out[j]);
            if(e)return e;
        }
        return 0;
    }
}
