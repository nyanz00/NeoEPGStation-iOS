/* Included after lab.c. Reuse its bounded feeder and independent pixel oracle. */
#include "lossless.h"
#include "rcomp.h"
#include <stdlib.h>
#ifdef __APPLE__
#include <mach/thread_info.h>
#endif
static double storage_cpu_ms(void) {
#ifdef _WIN32
    FILETIME a,b,k,u;
    if(GetThreadTimes(GetCurrentThread(),&a,&b,&k,&u)) {
        ULARGE_INTEGER x={0},y={0};x.LowPart=k.dwLowDateTime;x.HighPart=k.dwHighDateTime;
        y.LowPart=u.dwLowDateTime;y.HighPart=u.dwHighDateTime;return (x.QuadPart+y.QuadPart)/10000.0;
    }
#elif defined(__APPLE__)
    thread_basic_info_data_t info;mach_msg_type_number_t n=THREAD_BASIC_INFO_COUNT;
    thread_t t=mach_thread_self();kern_return_t e=thread_info(t,THREAD_BASIC_INFO,(thread_info_t)&info,&n);
    mach_port_deallocate(mach_task_self(),t);
    if(e==KERN_SUCCESS)return (info.user_time.seconds+info.system_time.seconds)*1000.0+
        (info.user_time.microseconds+info.system_time.microseconds)/1000.0;
#else
    struct timespec t;if(!clock_gettime(CLOCK_THREAD_CPUTIME_ID,&t))return t.tv_sec*1000.0+t.tv_nsec/1e6;
#endif
    return -1;
}
static int storage_input(Run *r,double gop) {
    if(!r->packets || r->count<4 || r->count>3000 || !isfinite(gop) || gop<=.5 || gop>65)return 1001;
    size_t total=0;
    for(size_t i=0;i<r->count;i++) {
        const NeoCheckpointPacket *p=&r->packets[i];
        if(!p->data || !p->size || p->size>64*1024*1024 || !isfinite(p->seconds) ||
           (i && p->seconds<r->packets[i-1].seconds))return 1001;
        total+=p->size;if(total>96*1024*1024)return 1005;
    }
    return check(r);
}
static int storage_save(Dav1dContext *c,int method,NeoLosslessCheckpoint **out) {
    int e=neo_lossless_capture(c,method,out);if(!e)e=neo_lossless_encode(*out);return e;
}
int neo_checkpoint_storage_run(const NeoCheckpointPacket *packets,size_t count,double gop,double distance,
    int method,NeoStorageResult *result,int(*cancelled)(void*),void *cookie) {
    if(!result)return 1001;
    memset(result,0,sizeof(*result));result->method=method;
    NeoCheckpointResult *out=&result->checkpoint;out->threads=6;out->packed=1;out->first_following_key_seconds=-1;
    Run r={0};r.packets=packets;r.count=count;r.began=now();r.cancelled=cancelled;r.cookie=cookie;r.result=out;
    Dav1dContext *c=NULL,*negative=NULL;NeoLosslessCheckpoint *saved=NULL,*temporary=NULL;
    NeoPackedCheckpoint *gold=NULL;Timing t={0};int error=0;
    out->before_bytes=sample(&r);out->failure_stage=1;
    TRY(storage_input(&r,gop));
    if((method!=0 && method!=4 && method!=7 && method!=9 && method!=10 && method!=11 && method!=12 && method!=13 && method!=14 && method!=15 && method!=16) || !isfinite(distance) || distance<=0) {error=1001;goto done;}
    if(neo_checkpoint_gpu_method(method)) {TRY(neo_checkpoint_gpu_begin(method,&result->gpu_setup_ms));}
    double wanted=gop*.9,position=wanted-fmin(distance,wanted*.5);
    while(r.cp<count && packets[r.cp].seconds<position)r.cp++;
    while(r.target<count && packets[r.target].seconds<wanted)r.target++;
    if(!r.cp || r.cp>=r.target || r.target>=count) {error=1001;goto done;}
    out->checkpoint_seconds=packets[r.cp].seconds;out->target_seconds=packets[r.target].seconds;
    TRY(open_decoder(&c,6,&out->frame_contexts));
    out->empty_rejected=neo_lossless_capture(c,method,&temporary)<0 && !temporary;
    if(!out->empty_rejected) {error=1002;goto done;}
    out->failure_stage=2;
    for(size_t i=0;i<r.cp;i++)TRY(feed(&r,c,i,ignore,NULL));
    double began=now();TRY(finish(&r,c,ignore,NULL));out->drain_before_save_ms=(now()-began)*1000;
    TRY(neo_packed_save(c,&gold));
    out->failure_stage=3;began=now();TRY(storage_save(c,method,&saved));out->save_ms=(now()-began)*1000;
    NeoLosslessStats stats;neo_lossless_stats(saved,&stats);out->retained_bytes=stats.held_bytes;
    out->picture_bytes=stats.pixel_bytes;out->state_bytes=stats.held_bytes-stats.pixel_bytes;
    out->original_pixels_detached=stats.detached;
    NeoPackedStats baseline;neo_packed_stats(gold,&baseline);out->unique_pictures=baseline.unique_pictures;
    if(!stats.detached || stats.held_bytes>96*1024*1024) {error=1005;goto done;}
    for(int k=0;k<NEO_CHECKPOINT_REPEATS;k++) {
        TRY(check(&r));double cpu=storage_cpu_ms();began=now();TRY(storage_save(c,method,&temporary));
        out->repeated_save_ms[k]=(now()-began)*1000;double after=storage_cpu_ms();
        result->save_cpu_ms[k]=cpu>=0 && after>=cpu?after-cpu:-1;
        if(neo_checkpoint_gpu_method(method)) {
            NeoRcompMetrics m;neo_checkpoint_gpu_metrics(method,&m);result->gpu_ms[k]=m.gpu_ms;result->gpu_wait_ms[k]=m.wait_ms;
            if(m.staging_bytes>result->gpu_staging_bytes)result->gpu_staging_bytes=m.staging_bytes;
            result->gpu_dispatches+=m.dispatches;
        }
        neo_lossless_free(&temporary);out->temporary_save_free_count++;
    }
    out->failure_stage=6;TRY(open_decoder(&negative,6,NULL));
    out->wrong_owner_rejected=neo_lossless_restore(negative,saved)<0;
    if(!out->wrong_owner_rejected) {error=1002;goto done;}
    dav1d_close(&negative);TRY(reject_busy(&r,6));
    out->failure_stage=4;TRY(suffix(&r,c));
    TRY(neo_lossless_restore(c,saved));TRY(neo_packed_verify_buffers(c,gold));out->allocation_verification_passes++;
    TRY(suffix(&r,c));
    TRY(neo_lossless_restore(c,saved));TRY(neo_packed_verify_buffers(c,gold));out->allocation_verification_passes++;
    if(!r.golden.data[0] || out->first_following_key_seconds<=wanted) {error=1004;goto done;}
    out->failure_stage=5;
    for(int k=0;k<NEO_CHECKPOINT_REPEATS;k++) {
        TRY(check(&r));memset(&t,0,sizeof(t));t.began=now();TRY(neo_lossless_restore(c,saved));
        out->restore_only_ms[k]=(now()-t.began)*1000;out->restore_count++;
        for(size_t i=r.cp;i<=r.target;i++)TRY(feed(&r,c,i,timed_output,&t));
        TRY(finish(&r,c,timed_output,&t));if(!t.picture.data[0]) {error=1004;goto done;}
        out->restored_ms[k]=t.ms;TRY(compare(&r,&r.golden,&t.picture));out->target_verified_count++;
        dav1d_picture_unref(&t.picture);out->sampled_footprint_bytes[k]=sample(&r);
        TRY(advance(&r,c,r.target+1,count));
    }
    out->failure_stage=0;
done:
    dav1d_picture_unref(&t.picture);dav1d_picture_unref(&r.golden);
    if(negative)dav1d_close(&negative);if(c)dav1d_close(&c);
    neo_lossless_free(&temporary);neo_lossless_free(&saved);neo_packed_free(&gold);
    if(neo_checkpoint_gpu_method(method))neo_checkpoint_gpu_end(method);
    out->after_bytes=neo_checkpoint_lab_footprint();out->status=error<0?1008:error;out->decoder_error=error<0?error:0;
    return out->status;
}
