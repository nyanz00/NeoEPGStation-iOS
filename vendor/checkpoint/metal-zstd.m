/* BSD-3-Clause. Bounded two-slot Metal compression pipeline. CPU preparation
 * writes directly into shared input, or a separately measured GPU preparer
 * reads one reusable raw-image buffer. Work tables are shared by ordered GPU
 * commands; CPU-owned input/output slots are not reused before completion. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "rcomp.h"
#include "metal-zstd-core.h"
#include "metal-zstd-parallel.h"
#include "metal-zstd-shader.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef NEO_MZSTD_NATIVE_DEBUG
#include <stdio.h>
#endif
#define MZ_BATCH 16u
#define MZ_BLOCK 65536u
#define MZ_HASH 32768u
#define MZ_SLOT (MZ_BLOCK+1024u)
#define MZ_LIMIT (32u*1024u*1024u)
typedef struct MzConfig {uint32_t count,length[16],offset[16];NeoRcompGeometry geometry;} MzConfig;
typedef struct MzPending {unsigned count,owners[16],passes,stages[13];} MzPending;
@interface NeoMetalZstdSession : NSObject {
@public
    id<MTLDevice> device;id<MTLLibrary> library;id<MTLCommandQueue> queue;
    id<MTLComputePipelineState> pipeline[18];id<MTLBuffer> buffers[10];
    id<MTLBuffer> inputs[2],outputs[2],sizes[2],raw;
    id<MTLCounterSampleBuffer> counters[2];id<MTLCommandBuffer> pending[2];
    MTLComputePassDescriptor *descriptors[2][13];
    MzPending info[2];uint64_t baseBytes;NeoRcompMetrics metrics;
    unsigned lastSlot;
}
@end
@implementation NeoMetalZstdSession
@end
static _Thread_local void *current;
static _Thread_local int scalar_control,gpu_preprocessing;
void neo_mzstd_scalar_control(int mode) {scalar_control=mode;}
void neo_mzstd_preprocessing_control(int enabled) {gpu_preprocessing=enabled!=0;}
static double mz_ms(void) {struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1000.+t.tv_nsec/1e6;}
static const char *names[18]={"nz_clear","nz_insert","nz_match","nz_parse","nz_compact","nz_hist","nz_tree","nz_tables","nz_chains","nz_prefix","nz_bases","nz_pack","nz_assemble","nz_encode_scalar","nz_fast_parse","nz_fast_compact","nz_fast_fse","nz_prepare"};
static int mz_pipeline(NeoMetalZstdSession *s,unsigned k) {
    if(s->pipeline[k])return 0;NSError *error=nil;
    id<MTLFunction> f=[s->library newFunctionWithName:[NSString stringWithUTF8String:names[k]]];if(!f)return 1011;
    s->pipeline[k]=[s->device newComputePipelineStateWithFunction:f error:&error];return s->pipeline[k]?0:1011;
}
int neo_mzstd_begin(double *setup) {
    if(setup)*setup=0;if(current)return 1001;
    @autoreleasepool {
        double began=mz_ms();NeoMetalZstdSession *s=[NeoMetalZstdSession new];s->device=MTLCreateSystemDefaultDevice();if(!s->device)return 1009;
        MTLCompileOptions *options=[MTLCompileOptions new];options.fastMathEnabled=NO;NSError *error=nil;
        s->library=[s->device newLibraryWithSource:[NSString stringWithUTF8String:neo_mzstd_shader_source] options:options error:&error];
        if(!s->library) {NSLog(@"Metal Zstandard shader: %@",error.localizedDescription);return 1011;}
        const unsigned live[]={0,1,2,5,6,9,10,11,12,14,15,16,17};
        for(unsigned j=0;j<sizeof(live)/sizeof(*live);j++)if(mz_pipeline(s,live[j]))return 1011;
        s->queue=[s->device newCommandQueue];if(!s->queue)return 1011;
        const size_t lens[10]={MZ_BATCH*MZ_BLOCK,MZ_BATCH*MZ_HASH*4,MZ_BATCH*MZ_BLOCK*4,MZ_BATCH*MZ_BLOCK*4,
            MZ_BATCH*16384*12,MZ_BATCH*MZ_BLOCK,MZ_BATCH*MZ_BLOCK*2,MZ_BATCH*MZ_SLOT,MZ_BATCH*4,MZ_BATCH*sizeof(NzWork)};
        size_t total=0;for(unsigned j=0;j<10;j++) {total+=lens[j];if(lens[j]>s->device.maxBufferLength)return 1005;
            s->buffers[j]=[s->device newBufferWithLength:lens[j] options:MTLResourceStorageModeShared];if(!s->buffers[j])return 1005;}
        s->inputs[0]=s->buffers[0];s->outputs[0]=s->buffers[7];s->sizes[0]=s->buffers[8];
        s->inputs[1]=[s->device newBufferWithLength:lens[0] options:MTLResourceStorageModeShared];
        s->outputs[1]=[s->device newBufferWithLength:lens[7] options:MTLResourceStorageModeShared];
        s->sizes[1]=[s->device newBufferWithLength:lens[8] options:MTLResourceStorageModeShared];
        total+=lens[0]+lens[7]+lens[8];if(!s->inputs[1] || !s->outputs[1] || !s->sizes[1] || total>MZ_LIMIT)return 1005;
        s->baseBytes=total;s->metrics.staging_bytes=total;
        if([s->device supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary])for(id<MTLCounterSet> set in s->device.counterSets)if([set.name isEqualToString:MTLCommonCounterSetTimestamp]) {
            for(unsigned slot=0;slot<2;slot++) {MTLCounterSampleBufferDescriptor *desc=[MTLCounterSampleBufferDescriptor new];desc.counterSet=set;desc.storageMode=MTLStorageModeShared;desc.sampleCount=26;
                s->counters[slot]=[s->device newCounterSampleBufferWithDescriptor:desc error:&error];}break;
        }
        for(unsigned slot=0;slot<2;slot++)for(unsigned pass=0;pass<13;pass++) {
            MTLComputePassDescriptor *desc=[MTLComputePassDescriptor computePassDescriptor];s->descriptors[slot][pass]=desc;
            if(s->counters[slot]) {desc.sampleBufferAttachments[0].sampleBuffer=s->counters[slot];desc.sampleBufferAttachments[0].startOfEncoderSampleIndex=pass*2;desc.sampleBufferAttachments[0].endOfEncoderSampleIndex=pass*2+1;}
        }
        current=(void*)CFBridgingRetain(s);if(setup)*setup=mz_ms()-began;return 0;
    }
}
void neo_mzstd_end(void) {@autoreleasepool {if(current) {NeoMetalZstdSession *s=(__bridge id)current;for(unsigned i=0;i<2;i++)[s->pending[i] waitUntilCompleted];id released=CFBridgingRelease(current);current=NULL;(void)released;}}}
void neo_mzstd_last_metrics(NeoRcompMetrics *out) {memset(out,0,sizeof(*out));if(current) {NeoMetalZstdSession *s=(__bridge id)current;*out=s->metrics;}}
static int mz_finish(NeoMetalZstdSession *s,unsigned slot,const NeoRcompInput *input,NeoRcompOutput *out) {
    id<MTLCommandBuffer> command=s->pending[slot];if(!command)return 0;MzPending info=s->info[slot];
    double began=mz_ms();[command waitUntilCompleted];double blocked=mz_ms()-began;
    s->metrics.wait_ms+=blocked;s->metrics.host_ms[3]+=blocked;s->metrics.wait_count++;s->pending[slot]=nil;s->lastSlot=slot;
    if(command.status!=MTLCommandBufferStatusCompleted)return 1011;
    if(command.GPUStartTime>0 && command.GPUEndTime>=command.GPUStartTime)s->metrics.gpu_ms+=(command.GPUEndTime-command.GPUStartTime)*1000;
    if(s->counters[slot]) {
        NSData *samples=[s->counters[slot] resolveCounterRange:NSMakeRange(0,info.passes*2)];
        BOOL valid=samples.length>=info.passes*2*sizeof(MTLCounterResultTimestamp);const MTLCounterResultTimestamp *ts=samples.bytes;
        for(unsigned p=0;valid && p<info.passes;p++)if(ts[p*2].timestamp==MTLCounterErrorValue || ts[p*2+1].timestamp==MTLCounterErrorValue || ts[p*2+1].timestamp<ts[p*2].timestamp)valid=NO;
        if(valid) {s->metrics.stage_timing_available++;for(unsigned p=0;p<info.passes;p++)s->metrics.stage_ms[info.stages[p]]+=(ts[p*2+1].timestamp-ts[p*2].timestamp)/1e6;}
    }
    began=mz_ms();const uint32_t *sizes=s->sizes[slot].contents;
    for(unsigned b=0;b<info.count;b++) {size_t n=sizes[b];if(!n || n>MZ_SLOT)return 1010;unsigned i=info.owners[b];
        size_t cap=input[i].size+((input[i].size+MZ_BLOCK-1)/MZ_BLOCK)*1024;if(out[i].size+n>cap)return 1010;
        memcpy(out[i].data+out[i].size,(const uint8_t*)s->outputs[slot].contents+(size_t)b*MZ_SLOT,n);out[i].size+=n;s->metrics.output_bytes+=n;
    }s->metrics.host_ms[4]+=mz_ms()-began;return 0;
}
#ifdef NEO_MZSTD_NATIVE_DEBUG
/* Native failure-only oracle. Never compiled into the iPhone library or used
 * in performance timing. Compare GPU tokens to the shipping scalar arithmetic. */
void neo_mzstd_debug_last(void) {
    if(!current)return;NeoMetalZstdSession *s=(__bridge id)current;unsigned slot=s->lastSlot;
    NzWork *all=s->buffers[9].contents;NzSeq *seqs=s->buffers[4].contents;NzU *tokens=s->buffers[3].contents;
    for(unsigned b=0;b<s->info[slot].count;b++) {
        NzWork *g=all+b,c={0};c.ns=g->ns;NzU *expected=calloc(NZ_BLOCK,sizeof(NzU));if(!expected)return;
        fprintf(stderr,"debug block=%u ns=%u nl=%u\n",b,g->ns,g->nl);
        NzSeq *seq=seqs+b*16384;
        for(unsigned j=0;j<c.ns;j++)for(unsigned f=0;f<3;f++)c.seqhist[f][nzp_code(seq[j],f)]++;
        for(unsigned f=0;c.ns && f<3;f++) {
            unsigned mode;c.tableSize[f]=nz_seqtable(c.tableHeader[f],c.fse+f,c.seqhist[f],c.ns,&mode);c.mode[f]=mode;
            if(g->mode[f]!=mode || g->tableSize[f]!=c.tableSize[f] || memcmp(g->tableHeader[f],c.tableHeader[f],c.tableSize[f]))fprintf(stderr,"debug table mismatch family=%u mode GPU=%u CPU=%u size GPU=%u CPU=%u\n",f,g->mode[f],mode,g->tableSize[f],c.tableSize[f]);
            nzp_chain(&c,seq,expected,f);
            for(unsigned j=0;j<c.ns;j++)if(tokens[b*NZ_BLOCK+j*4+f]!=expected[j*4+f]) {fprintf(stderr,"debug token mismatch family=%u seq=%u GPU=%08x CPU=%08x log=%u GPUstate=%u CPUstate=%u\n",f,j,tokens[b*NZ_BLOCK+j*4+f],expected[j*4+f],c.fse[f].log,g->state[f],c.state[f]);break;}
        }free(expected);
    }
}
#endif
static int mz_submit(NeoMetalZstdSession *s,unsigned slot,MzConfig *cfg,MzPending *info,int prepare) {
    static const unsigned fast[]={0,1,2,14,15,5,6,16,9,10,11,12};
    static const unsigned old[]={0,1,2,3,4,5,6,7,8,9,10,11,12};
    static const unsigned scalar[]={0,1,2,13};
    unsigned kernels[13],passes=0;if(prepare)kernels[passes++]=17;
    const unsigned *list=scalar_control==1?scalar:scalar_control==2?old:fast;
    unsigned count=scalar_control==1?4:scalar_control==2?13:12;
    if(passes+count>13)return 1001;for(unsigned p=0;p<count;p++)kernels[passes++]=list[p];
    double began=mz_ms();id<MTLCommandBuffer> command=[s->queue commandBuffer];if(!command)return 1011;
    id<MTLBuffer> bindings[9];NSUInteger offsets[9]={0};
    for(unsigned j=0;j<9;j++)bindings[j]=j==0?s->inputs[slot]:j==7?s->outputs[slot]:j==8?s->sizes[slot]:s->buffers[j];
    for(unsigned pass=0;pass<passes;pass++) {
        unsigned k=kernels[pass];if(mz_pipeline(s,k))return 1011;
        unsigned stage=k<=2?0:k==3 || k==4 || k==14 || k==15?1:k==5?2:k==6?3:k==7 || k==8 || k==16?4:k==12 || k==13?6:k==17?7:5;info->stages[pass]=stage;
        MTLComputePassDescriptor *desc=s->descriptors[slot][pass];
        id<MTLComputeCommandEncoder> enc=[command computeCommandEncoderWithDescriptor:desc];if(!enc)return 1011;
        [enc setComputePipelineState:s->pipeline[k]];
        [enc setBuffers:bindings offsets:offsets withRange:NSMakeRange(0,9)];
        [enc setBytes:cfg length:sizeof(*cfg) atIndex:9];[enc setBuffer:s->buffers[9] offset:0 atIndex:10];
        if(prepare)[enc setBuffer:s->raw offset:0 atIndex:11];
        BOOL grouped=k==4 || k==5 || k==6 || k==9 || k==10 || k==12 || k==14 || k==15 || k==16;
        NSUInteger n=k==0?cfg->count*MZ_HASH:k==3?cfg->count*16:k==7 || k==8?cfg->count*3:k==13?cfg->count:cfg->count*MZ_BLOCK;
        NSUInteger width=grouped?128:k==13?1:MIN(n,MIN(s->pipeline[k].threadExecutionWidth,s->pipeline[k].maxTotalThreadsPerThreadgroup));
        if(!width || width>s->pipeline[k].maxTotalThreadsPerThreadgroup)return 1011;
        if(grouped) {NSUInteger groups=cfg->count*(k==5 || k==14?16:k==9?5*128:k==10?5:1);[enc dispatchThreadgroups:MTLSizeMake(groups,1,1) threadsPerThreadgroup:MTLSizeMake(width,1,1)];}
        else [enc dispatchThreads:MTLSizeMake(n,1,1) threadsPerThreadgroup:MTLSizeMake(width,1,1)];[enc endEncoding];
    }
    info->count=cfg->count;info->passes=passes;s->info[slot]=*info;s->pending[slot]=command;
    [command commit];s->metrics.host_ms[2]+=mz_ms()-began;s->metrics.dispatches+=passes;s->metrics.batch_count++;
    int active=(s->pending[0]!=nil)+(s->pending[1]!=nil);if(active>s->metrics.max_in_flight)s->metrics.max_in_flight=active;return 0;
}
int neo_mzstd_gpu_pack(const NeoRcompInput *input,NeoRcompOutput *out,unsigned images) {
    if(!current)return 1009;if(!input || !out || !images || images>8)return 1001;
    @autoreleasepool {
        NeoMetalZstdSession *s=(__bridge id)current;memset(&s->metrics,0,sizeof(s->metrics));s->metrics.staging_bytes=s->baseBytes+(s->raw?s->raw.length:0);
        size_t total=0,maxRaw=0;for(unsigned i=0;i<images;i++) {
            if(!input[i].data || !input[i].size || input[i].size>48*1024*1024 || !nzi_valid(input[i].geometry,input[i].size))return 1001;
            total+=input[i].size;if(gpu_preprocessing && input[i].geometry && input[i].size>maxRaw)maxRaw=input[i].size;
        }if(total>48*1024*1024)return 1005;
        if(maxRaw && (!s->raw || s->raw.length<maxRaw)) {
            size_t cap=(maxRaw+4095)&~(size_t)4095;if(s->baseBytes+cap>MZ_LIMIT)return 1005;
            s->raw=[s->device newBufferWithLength:cap options:MTLResourceStorageModeShared];if(!s->raw)return 1005;
        }s->metrics.staging_bytes=s->baseBytes+(s->raw?s->raw.length:0);
        for(unsigned i=0;i<images;i++) {size_t cap=input[i].size+((input[i].size+MZ_BLOCK-1)/MZ_BLOCK)*1024;
            out[i].data=malloc(cap);out[i].size=0;if(!out[i].data)return 1005;}
        unsigned image=0,next=0;size_t offset=0;int uploaded=-1,error=0;
        while(image<images && !error) {
          @autoreleasepool {
            int prepare=gpu_preprocessing && input[image].geometry;
            if(prepare && uploaded!=(int)image) {
                error=mz_finish(s,next,input,out);if(!error)error=mz_finish(s,next^1,input,out);if(error)break;
                double began=mz_ms();memcpy(s->raw.contents,input[image].data,input[image].size);s->metrics.input_bytes+=input[image].size;s->metrics.host_ms[1]+=mz_ms()-began;uploaded=(int)image;
            }
            error=mz_finish(s,next,input,out);if(error)break;
            MzConfig cfg={0};MzPending info={0};if(prepare)cfg.geometry=*input[image].geometry;
            unsigned owner=image;double began=mz_ms();
            while(cfg.count<MZ_BATCH && image<images) {
                if((gpu_preprocessing && input[image].geometry)!=prepare || (prepare && image!=owner))break;
                size_t size=MIN((size_t)MZ_BLOCK,input[image].size-offset);unsigned b=cfg.count++;cfg.length[b]=(uint32_t)size;cfg.offset[b]=(uint32_t)offset;info.owners[b]=image;
                if(!prepare) {nzi_prepare(input[image].data,input[image].geometry,offset,size,(uint8_t*)s->inputs[next].contents+(size_t)b*MZ_BLOCK);s->metrics.input_bytes+=size;}
                offset+=size;if(offset==input[image].size) {image++;offset=0;}
            }
            s->metrics.host_ms[0]+=mz_ms()-began;error=mz_submit(s,next,&cfg,&info,prepare);
            if(!error && scalar_control==2)error=mz_finish(s,next,input,out); /* Native build-277 control. */
            next^=1;
          }
        }
        if(!error)error=mz_finish(s,next,input,out);if(!error)error=mz_finish(s,next^1,input,out);
        if(error) {for(unsigned slot=0;slot<2;slot++) {[s->pending[slot] waitUntilCompleted];s->pending[slot]=nil;}return error;}
        double began=mz_ms();for(unsigned i=0;i<images;i++) {void *small=realloc(out[i].data,out[i].size);if(small)out[i].data=small;}s->metrics.host_ms[4]+=mz_ms()-began;
        return 0;
    }
}
