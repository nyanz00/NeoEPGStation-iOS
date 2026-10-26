/* lsCOMP lossless adaptation. Copyright (c) 2025 UChicago Argonne and
 * University of Iowa. Original license: vendor/lscomp/LICENSE.
 * iOS host bridge; four ordered dispatches, no cross-threadgroup spin waits. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "lscomp.h"
#include "lscomp-shader.h"
#include <string.h>
#include <time.h>
_Static_assert(sizeof(NeoLsImage)==32 && sizeof(NeoLsConfig)==268,"Metal configuration layout");
@interface NeoCheckpointLsSession : NSObject {
@public
    id<MTLDevice> device;
    id<MTLComputePipelineState> pipeline[4];
    id<MTLCommandQueue> queue;
    id<MTLBuffer> input,widths,offsets,groups,bases,output;
    NeoRcompMetrics metrics;
}
@end
@implementation NeoCheckpointLsSession
@end
static _Thread_local void *current;
static double ms(void) {struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1000.0+t.tv_nsec/1e6;}
int neo_lscomp_begin(double *setup_ms) {
    if(setup_ms)*setup_ms=0;if(current)return 1001;
    @autoreleasepool {
        double start=ms();NeoCheckpointLsSession *s=[NeoCheckpointLsSession new];s->device=MTLCreateSystemDefaultDevice();if(!s->device)return 1009;
        MTLCompileOptions *options=[MTLCompileOptions new];options.fastMathEnabled=NO;NSError *error=nil;
        id<MTLLibrary> library=[s->device newLibraryWithSource:[NSString stringWithUTF8String:neo_lscomp_shader_source] options:options error:&error];
        if(!library) {NSLog(@"Checkpoint lsCOMP shader compilation: %@",error.localizedDescription);return 1011;}
        const char *names[4]={"neo_ls_analyse","neo_ls_scan","neo_ls_bases","neo_ls_emit"};
        for(int j=0;j<4;j++) {
            id<MTLFunction> f=[library newFunctionWithName:[NSString stringWithUTF8String:names[j]]];if(!f)return 1011;
            s->pipeline[j]=[s->device newComputePipelineStateWithFunction:f error:&error];if(!s->pipeline[j])return 1011;
        }
        if(s->pipeline[1].maxTotalThreadsPerThreadgroup<256)return 1011;
        s->queue=[s->device newCommandQueue];if(!s->queue)return 1011;
        current=(void*)CFBridgingRetain(s);if(setup_ms)*setup_ms=ms()-start;return 0;
    }
}
void neo_lscomp_end(void) {@autoreleasepool {if(current) {id released=CFBridgingRelease(current);current=NULL;(void)released;}}}
void neo_lscomp_last_metrics(NeoRcompMetrics *out) {memset(out,0,sizeof(*out));if(current) {NeoCheckpointLsSession *s=(__bridge id)current;*out=s->metrics;}}
static BOOL buffer(id<MTLDevice> device,id<MTLBuffer> __strong *p,size_t size) {
    if(*p && (*p).length>=size)return YES;*p=[device newBufferWithLength:size options:MTLResourceStorageModeShared];return *p!=nil;
}
int neo_lscomp_gpu_pack(const NeoRcompInput *in,NeoRcompOutput *out,unsigned count) {
    if(!current)return 1009;if(!in || !out || !count || count>8)return 1001;
    @autoreleasepool {
        NeoCheckpointLsSession *s=(__bridge id)current;memset(&s->metrics,0,sizeof(s->metrics));
        NeoLsConfig cfg={0};cfg.images=count;size_t bytes=0,capacity=0;
        for(unsigned j=0;j<count;j++) {
            int e=neo_lscomp_geometry(&in[j],&cfg.image[j]);if(e)return e;
            cfg.image[j].first_byte=(uint32_t)bytes;cfg.image[j].first_tile=cfg.tiles;cfg.tiles+=cfg.image[j].tiles;bytes+=in[j].size;capacity+=(size_t)cfg.image[j].tiles*cfg.image[j].word_bytes*64;
        }
        if(bytes>48*1024*1024 || cfg.tiles>1024*1024)return 1005;
        cfg.groups=(cfg.tiles+255)/256;
        size_t lens[6]={bytes,cfg.tiles,(size_t)cfg.tiles*4,(size_t)cfg.groups*4,(size_t)cfg.groups*4,capacity},sum=0;
        for(int j=0;j<6;j++) {sum+=lens[j];if(lens[j]>s->device.maxBufferLength)return 1005;}
        if(sum>128*1024*1024)return 1005;
        if(!buffer(s->device,&s->input,lens[0]) || !buffer(s->device,&s->widths,lens[1]) || !buffer(s->device,&s->offsets,lens[2]) ||
           !buffer(s->device,&s->groups,lens[3]) || !buffer(s->device,&s->bases,lens[4]) || !buffer(s->device,&s->output,lens[5]))return 1005;
        s->metrics.staging_bytes=s->input.length+s->widths.length+s->offsets.length+s->groups.length+s->bases.length+s->output.length;
        if(s->metrics.staging_bytes>128*1024*1024)return 1005;
        for(unsigned j=0;j<count;j++)memcpy((uint8_t*)s->input.contents+cfg.image[j].first_byte,in[j].data,in[j].size);
        id<MTLCommandBuffer> command=[s->queue commandBuffer];if(!command)return 1011;
        for(int pass=0;pass<4;pass++) {
            id<MTLComputeCommandEncoder> enc=[command computeCommandEncoder];if(!enc)return 1011;
            [enc setComputePipelineState:s->pipeline[pass]];
            [enc setBuffer:s->input offset:0 atIndex:0];[enc setBuffer:s->widths offset:0 atIndex:1];[enc setBuffer:s->offsets offset:0 atIndex:2];
            [enc setBuffer:s->groups offset:0 atIndex:3];[enc setBuffer:s->bases offset:0 atIndex:4];[enc setBuffer:s->output offset:0 atIndex:5];
            [enc setBytes:&cfg length:sizeof(cfg) atIndex:6];
            if(pass==1)[enc dispatchThreadgroups:MTLSizeMake(cfg.groups,1,1) threadsPerThreadgroup:MTLSizeMake(256,1,1)];
            else {
                NSUInteger n=pass==2?1:cfg.tiles,width=MIN(n,MIN(s->pipeline[pass].threadExecutionWidth,s->pipeline[pass].maxTotalThreadsPerThreadgroup));
                if(!width)return 1011;[enc dispatchThreads:MTLSizeMake(n,1,1) threadsPerThreadgroup:MTLSizeMake(width,1,1)];
            }
            [enc endEncoding];
        }
        double start=ms();[command commit];[command waitUntilCompleted];s->metrics.wait_ms=ms()-start;s->metrics.dispatches=4;
        if(command.status!=MTLCommandBufferStatusCompleted)return 1011;
        if(command.GPUStartTime>0 && command.GPUEndTime>=command.GPUStartTime)s->metrics.gpu_ms=(command.GPUEndTime-command.GPUStartTime)*1000;
        const uint8_t *w=s->widths.contents;const uint32_t *o=s->offsets.contents,*b=s->bases.contents;
        for(unsigned j=0;j<count;j++) {
            NeoLsImage *g=&cfg.image[j];size_t first=g->first_tile,last=first+g->tiles-1;
            size_t begin=(size_t)o[first]+b[first/256],end=(size_t)o[last]+b[last/256]+(size_t)w[last]*8;
            if(begin>end || end>s->output.length)return 1010;
            int e=neo_lscomp_assemble(g,w+first,(const uint8_t*)s->output.contents+begin,end-begin,&out[j]);if(e)return e;
        }
        return 0;
    }
}
