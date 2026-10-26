/* BSD-3-Clause. iPhone Metal Zstandard diagnostic backend. CPU handles only
 * input/output transfer here; all match/parse/entropy/frame work is in Metal. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "rcomp.h"
#include "metal-zstd-core.h"
#include "metal-zstd-parallel.h"
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
    id<MTLLibrary> library;
    id<MTLCommandQueue> queue;
    id<MTLComputePipelineState> pipeline[14];
    id<MTLBuffer> buffers[10];
    id<MTLCounterSampleBuffer> counters;
    NeoRcompMetrics metrics;
}
@end
@implementation NeoMetalZstdSession
@end
static _Thread_local void *current;
static _Thread_local int scalar_control;
void neo_mzstd_scalar_control(int enabled) {scalar_control=enabled!=0;}
static double mz_ms(void) {struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1000.0+t.tv_nsec/1e6;}
int neo_mzstd_begin(double *setup) {
    if(setup)*setup=0;if(current)return 1001;
    @autoreleasepool {
        double began=mz_ms();NeoMetalZstdSession *s=[NeoMetalZstdSession new];s->device=MTLCreateSystemDefaultDevice();if(!s->device)return 1009;
        MTLCompileOptions *options=[MTLCompileOptions new];options.fastMathEnabled=NO;NSError *error=nil;
        id<MTLLibrary> lib=[s->device newLibraryWithSource:[NSString stringWithUTF8String:neo_mzstd_shader_source] options:options error:&error];
        if(!lib) {NSLog(@"Metal Zstandard shader: %@",error.localizedDescription);return 1011;}
        s->library=lib;
        const char *names[14]={"nz_clear","nz_insert","nz_match","nz_parse","nz_compact","nz_hist","nz_tree","nz_tables","nz_chains","nz_prefix","nz_bases","nz_pack","nz_assemble","nz_encode_scalar"};
        for(unsigned j=0;j<13;j++) {
            id<MTLFunction> f=[lib newFunctionWithName:[NSString stringWithUTF8String:names[j]]];if(!f)return 1011;
            s->pipeline[j]=[s->device newComputePipelineStateWithFunction:f error:&error];if(!s->pipeline[j])return 1011;
        }
        s->queue=[s->device newCommandQueue];if(!s->queue)return 1011;
        const size_t lens[10]={MZ_BATCH*MZ_BLOCK,MZ_BATCH*MZ_HASH*4,MZ_BATCH*MZ_BLOCK*4,MZ_BATCH*MZ_BLOCK*4,
            MZ_BATCH*16384*12,MZ_BATCH*MZ_BLOCK,MZ_BATCH*MZ_BLOCK*2,MZ_BATCH*MZ_SLOT,MZ_BATCH*4,MZ_BATCH*sizeof(NzWork)};
        size_t total=0;for(unsigned j=0;j<10;j++) {total+=lens[j];if(lens[j]>s->device.maxBufferLength)return 1005;
            s->buffers[j]=[s->device newBufferWithLength:lens[j] options:MTLResourceStorageModeShared];if(!s->buffers[j])return 1005;}
        if(total>32*1024*1024)return 1005;s->metrics.staging_bytes=total;
        if([s->device supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary]) {
            for(id<MTLCounterSet> set in s->device.counterSets)if([set.name isEqualToString:MTLCommonCounterSetTimestamp]) {
                MTLCounterSampleBufferDescriptor *desc=[MTLCounterSampleBufferDescriptor new];desc.counterSet=set;desc.storageMode=MTLStorageModeShared;desc.sampleCount=26;
                s->counters=[s->device newCounterSampleBufferWithDescriptor:desc error:&error];break;
            }
        }
        current=(void*)CFBridgingRetain(s);if(setup)*setup=mz_ms()-began;return 0;
    }
}
void neo_mzstd_end(void) {@autoreleasepool {if(current) {id released=CFBridgingRelease(current);current=NULL;(void)released;}}}
void neo_mzstd_last_metrics(NeoRcompMetrics *out) {memset(out,0,sizeof(*out));if(current) {NeoMetalZstdSession *s=(__bridge id)current;*out=s->metrics;}}
int neo_mzstd_gpu_pack(const NeoRcompInput *input,NeoRcompOutput *out,unsigned images) {
    if(!current)return 1009;if(!input || !out || !images || images>8)return 1001;
    @autoreleasepool {
        NeoMetalZstdSession *s=(__bridge id)current;uint64_t staging=s->metrics.staging_bytes;memset(&s->metrics,0,sizeof(s->metrics));s->metrics.staging_bytes=staging;
        /* Do not allocate the old scalar pipeline's large private workspace in
         * the iPhone trial. Only the native before/after control requests it. */
        if(scalar_control && !s->pipeline[13]) {
            NSError *error=nil;id<MTLFunction> f=[s->library newFunctionWithName:@"nz_encode_scalar"];
            s->pipeline[13]=[s->device newComputePipelineStateWithFunction:f error:&error];if(!s->pipeline[13])return 1011;
        }
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
            unsigned passes=scalar_control?4:13;const unsigned stages[13]={0,0,0,1,1,2,3,4,4,5,5,5,6};
            for(unsigned pass=0;pass<passes;pass++) {
                unsigned kernel=scalar_control && pass==3?13:pass;
                MTLComputePassDescriptor *desc=[MTLComputePassDescriptor computePassDescriptor];
                if(s->counters) {desc.sampleBufferAttachments[0].sampleBuffer=s->counters;desc.sampleBufferAttachments[0].startOfEncoderSampleIndex=pass*2;desc.sampleBufferAttachments[0].endOfEncoderSampleIndex=pass*2+1;}
                id<MTLComputeCommandEncoder> enc=[command computeCommandEncoderWithDescriptor:desc];if(!enc)return 1011;
                [enc setComputePipelineState:s->pipeline[kernel]];
                for(unsigned j=0;j<9;j++)[enc setBuffer:s->buffers[j] offset:0 atIndex:j];[enc setBytes:&cfg length:sizeof(cfg) atIndex:9];
                [enc setBuffer:s->buffers[9] offset:0 atIndex:10];
                BOOL grouped=kernel==4 || kernel==5 || kernel==6 || kernel==9 || kernel==10 || kernel==12;
                NSUInteger n=kernel==0?cfg.count*MZ_HASH:kernel==3?cfg.count*16:kernel==7 || kernel==8?cfg.count*3:kernel==13?cfg.count:cfg.count*MZ_BLOCK;
                NSUInteger width=grouped?128:kernel==13?1:MIN(n,MIN(s->pipeline[kernel].threadExecutionWidth,s->pipeline[kernel].maxTotalThreadsPerThreadgroup));
                if(!width || width>s->pipeline[kernel].maxTotalThreadsPerThreadgroup)return 1011;
                if(grouped) {NSUInteger groups=cfg.count*(kernel==5?16:kernel==9?5*128:kernel==10?5:1);[enc dispatchThreadgroups:MTLSizeMake(groups,1,1) threadsPerThreadgroup:MTLSizeMake(width,1,1)];}
                else [enc dispatchThreads:MTLSizeMake(n,1,1) threadsPerThreadgroup:MTLSizeMake(width,1,1)];[enc endEncoding];
            }
            double began=mz_ms();[command commit];[command waitUntilCompleted];s->metrics.wait_ms+=mz_ms()-began;s->metrics.dispatches+=passes;
            if(command.status!=MTLCommandBufferStatusCompleted)return 1011;
            if(command.GPUStartTime>0 && command.GPUEndTime>=command.GPUStartTime)s->metrics.gpu_ms+=(command.GPUEndTime-command.GPUStartTime)*1000;
            if(s->counters) {
                NSData *samples=[s->counters resolveCounterRange:NSMakeRange(0,passes*2)];
                BOOL valid=samples.length>=passes*2*sizeof(MTLCounterResultTimestamp);const MTLCounterResultTimestamp *ts=samples.bytes;
                for(unsigned p=0;valid && p<passes;p++)if(ts[p*2].timestamp==MTLCounterErrorValue || ts[p*2+1].timestamp==MTLCounterErrorValue || ts[p*2+1].timestamp<ts[p*2].timestamp)valid=NO;
                if(valid) {s->metrics.stage_timing_available++;for(unsigned p=0;p<passes;p++)s->metrics.stage_ms[scalar_control && p==3?6:stages[p]]+=(ts[p*2+1].timestamp-ts[p*2].timestamp)/1e6;}
            }
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
