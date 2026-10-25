/* BSD-2-Clause. Uses the exact checkpoint implementation from the PC proof. */
#include "config.h"
#include <errno.h>
#include <math.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <time.h>
#endif
#ifdef __APPLE__
#include <mach/mach.h>
#endif
#include "dav1d/dav1d.h"
#include "neo_checkpoint.h"
#include "NeoCheckpointLab.h"

typedef struct Pictures { Dav1dPicture p[32]; unsigned count; } Pictures;
typedef struct Run {
    const NeoCheckpointPacket *packets;
    size_t count;
    double began;
    int (*cancelled)(void *);
    void *cookie;
    NeoCheckpointResult *result;
} Run;
static double now(void) {
#ifdef _WIN32
    LARGE_INTEGER t,f; QueryPerformanceCounter(&t); QueryPerformanceFrequency(&f);
    return (double)t.QuadPart/f.QuadPart;
#else
    struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t);
    return t.tv_sec+t.tv_nsec*1e-9;
#endif
}
static uint64_t footprint(void) {
#ifdef __APPLE__
    task_vm_info_data_t info; mach_msg_type_number_t n=TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&info,&n)==KERN_SUCCESS)
        return info.phys_footprint;
#endif
    return 0;
}
static uint64_t sample(Run *r) {
    uint64_t n=footprint();
    if(n>r->result->sampled_peak_bytes) r->result->sampled_peak_bytes=n;
    return n;
}
static int check(Run *r) {
    if (r->cancelled && r->cancelled(r->cookie)) return 1006;
    return now()-r->began>180 ? 1007 : 0;
}
static void quiet(void *p,const char *s,va_list args) {(void)p;(void)s;(void)args;}
static int open_decoder(Dav1dContext **out) {
    Dav1dSettings s; dav1d_default_settings(&s);
    s.n_threads=1; s.max_frame_delay=1; s.logger.callback=quiet;
    return dav1d_open(out,&s);
}
static void release(Pictures *p) {
    for(unsigned i=0;i<p->count;i++) dav1d_picture_unref(&p->p[i]);
    p->count=0;
}
static int drain(Dav1dContext *c,Pictures *p) {
    for(;;) {
        Dav1dPicture pic={0}; int error=dav1d_get_picture(c,&pic);
        if(error==DAV1D_ERR(EAGAIN)) return 0;
        if(error) return error;
        if(p->count==32) {dav1d_picture_unref(&pic);return 1001;}
        p->p[p->count++]=pic;
    }
}
static int feed(Run *r,Dav1dContext *c,size_t index,Pictures *p) {
    int error=check(r); if(error) return error;
    const NeoCheckpointPacket *src=&r->packets[index];
    Dav1dData data={0}; uint8_t *bytes=dav1d_data_create(&data,src->size);
    if(!bytes) return DAV1D_ERR(ENOMEM);
    memcpy(bytes,src->data,src->size);
    /* Index uniquely associates output with original packet PTS (including
     * show-existing frames). Relative seconds stay in the immutable input. */
    data.m.timestamp=(int64_t)index; data.m.offset=(int64_t)index;
    error=dav1d_send_data(c,&data);
    if(error==DAV1D_ERR(EAGAIN)) {
        error=drain(c,p); if(!error) error=dav1d_send_data(c,&data);
    }
    dav1d_data_unref(&data);
    return error ? error : drain(c,p);
}
static int prefix(Run *r,Dav1dContext *c,size_t end) {
    for(size_t i=0;i<end;i++) {
        Pictures p={0}; int error=feed(r,c,i,&p); release(&p);
        if(error) return error;
    }
    return 0;
}
static int compare(Run *r,const Pictures *a,const Pictures *b) {
    if(a->count!=b->count) return 1003;
    for(unsigned i=0;i<a->count;i++) {
        const Dav1dPicture *p=&a->p[i], *q=&b->p[i];
        if(p->p.w!=q->p.w || p->p.h!=q->p.h || p->p.bpc!=q->p.bpc ||
           p->p.layout!=q->p.layout || p->m.timestamp!=q->m.timestamp ||
           p->m.offset!=q->m.offset || p->frame_hdr->frame_type!=q->frame_hdr->frame_type)
            return 1003;
        if(p->m.timestamp<0 || (uint64_t)p->m.timestamp>=r->count) return 1003;
        r->result->width=p->p.w; r->result->height=p->p.h; r->result->bit_depth=p->p.bpc;
        if(p->frame_hdr->frame_type==DAV1D_FRAME_TYPE_KEY && r->result->first_following_key_seconds<0)
            r->result->first_following_key_seconds=r->packets[p->m.timestamp].seconds;
        int chroma=p->p.layout!=DAV1D_PIXEL_LAYOUT_I400;
        int hs=p->p.layout!=DAV1D_PIXEL_LAYOUT_I444, vs=p->p.layout==DAV1D_PIXEL_LAYOUT_I420;
        for(int plane=0;plane<(chroma?3:1);plane++) {
            int w=plane?(p->p.w+((1<<hs)-1))>>hs:p->p.w;
            int h=plane?(p->p.h+((1<<vs)-1))>>vs:p->p.h;
            size_t bytes=(size_t)w*(p->p.bpc>8?2:1);
            for(int y=0;y<h;y++) {
                const uint8_t *x=(const uint8_t *)p->data[plane]+y*p->stride[plane?1:0];
                const uint8_t *z=(const uint8_t *)q->data[plane]+y*q->stride[plane?1:0];
                if(memcmp(x,z,bytes)) return 1003;
                r->result->compared_pixel_bytes+=bytes;
            }
        }
        r->result->compared_frames++;
    }
    return 0;
}
static int suffix(Run *r,Dav1dContext *a,Dav1dContext *b,size_t start) {
    for(size_t i=start;i<r->count;i++) {
        Pictures x={0},y={0};
        int error=feed(r,a,i,&x);
        if(!error) error=feed(r,b,i,&y);
        if(!error) error=compare(r,&x,&y);
        release(&x); release(&y); if(error) return error;
    }
    sample(r); return 0;
}
static int target(Run *r,Dav1dContext *c,size_t start,double seconds,double *ms,double *actual) {
    double began=now();
    for(size_t i=start;i<r->count;i++) {
        Pictures p={0}; int error=feed(r,c,i,&p),found=0;
        if(!error) for(unsigned j=0;j<p.count;j++) {
            int64_t index=p.p[j].m.timestamp;
            if(index<0 || (uint64_t)index>=r->count) {error=1003;break;}
            if(r->packets[index].seconds>=seconds) {found=1;*actual=r->packets[index].seconds;}
        }
        release(&p);
        if(error) return error;
        if(found) {*ms=(now()-began)*1000;return 0;}
    }
    return 1004;
}
#define TRY(call) do {error=(call);if(error) goto done;} while(0)
int neo_checkpoint_lab_run(const NeoCheckpointPacket *packets,size_t count,
    double gop,double distance,NeoCheckpointResult *out,int(*cancelled)(void*),void *cookie) {
    if(!out) return 1001;
    memset(out,0,sizeof(*out)); out->first_following_key_seconds=-1;
    Run r={packets,count,now(),cancelled,cookie,out};
    Dav1dContext *c=NULL,*oracle=NULL,*negative=NULL;
    NeoCheckpoint *saved=NULL,*temporary=NULL;
    int error=0; size_t cp=0,total=0;
    out->before_bytes=sample(&r);
    if(!packets || count<4 || count>3000 || !isfinite(gop) || gop<=.5 || gop>65 ||
       !isfinite(distance) || distance<=0) {error=1001;goto done;}
    for(size_t i=0;i<count;i++) {
        if(!packets[i].data || !packets[i].size || packets[i].size>64*1024*1024 ||
           !isfinite(packets[i].seconds) || (i && packets[i].seconds<packets[i-1].seconds)) {error=1001;goto done;}
        total+=packets[i].size; if(total>96*1024*1024) {error=1005;goto done;}
    }
    double wanted=gop*.9, position=wanted-fmin(distance,wanted*.5);
    while(cp<count && packets[cp].seconds<position) cp++;
    if(!cp || cp==count || packets[cp].seconds>=wanted) {error=1001;goto done;}
    out->checkpoint_seconds=packets[cp].seconds;
    TRY(open_decoder(&c));
    out->empty_rejected=neo_checkpoint_save(c,&temporary)<0 && !temporary;
    if(!out->empty_rejected) {error=1002;goto done;}
    TRY(prefix(&r,c,cp));
    double began=now(); TRY(neo_checkpoint_save(c,&saved)); out->save_ms=(now()-began)*1000;
    NeoCheckpointStats stats; neo_checkpoint_stats(saved,&stats);
    out->retained_bytes=stats.retained_bytes; out->state_bytes=stats.state_bytes;
    out->picture_bytes=stats.picture_bytes; out->unique_pictures=stats.unique_pictures;
    if(out->retained_bytes>96*1024*1024) {error=1005;goto done;}
    TRY(open_decoder(&oracle)); TRY(prefix(&r,oracle,cp));
    out->wrong_owner_rejected=neo_checkpoint_restore(oracle,saved)<0;
    if(!out->wrong_owner_rejected) {error=1002;goto done;}
    TRY(suffix(&r,oracle,c,cp)); dav1d_close(&oracle);
    for(int k=0;k<NEO_CHECKPOINT_REPEATS;k++) {
        TRY(open_decoder(&oracle)); TRY(prefix(&r,oracle,cp));
        TRY(neo_checkpoint_restore(c,saved)); out->restore_count++;
        TRY(neo_checkpoint_save(c,&temporary)); neo_checkpoint_free(&temporary);
        out->temporary_save_free_count++;
        TRY(suffix(&r,oracle,c,cp)); dav1d_close(&oracle);
        out->sampled_footprint_bytes[k]=sample(&r);
    }
    if(out->first_following_key_seconds<=wanted || !out->compared_frames) {error=1004;goto done;}
    TRY(open_decoder(&negative));
    { Pictures p={0}; int e=feed(&r,negative,cp,&p);
      out->suffix_without_state_rejected=e<0 || (!e && !p.count); release(&p);
      if(!out->suffix_without_state_rejected) {error=e?e:1002;goto done;} }
    dav1d_close(&negative);
    for(int k=0;k<NEO_CHECKPOINT_REPEATS;k++) {
        double actual=0,restored_actual=0;
        dav1d_flush(c);
        TRY(target(&r,c,0,wanted,&out->baseline_ms[k],&actual));
        began=now(); TRY(neo_checkpoint_restore(c,saved)); out->restore_only_ms[k]=(now()-began)*1000;
        double decode_ms=0; TRY(target(&r,c,cp,wanted,&decode_ms,&restored_actual));
        out->restored_ms[k]=(now()-began)*1000;
        if(actual!=restored_actual) {error=1003;goto done;}
        out->target_seconds=actual; sample(&r);
    }
done:
    if(oracle) dav1d_close(&oracle);
    if(negative) dav1d_close(&negative);
    if(c) dav1d_close(&c);
    neo_checkpoint_free(&temporary); neo_checkpoint_free(&saved);
    out->after_bytes=footprint();
    out->status=error<0 ? 1008 : error; out->decoder_error=error<0 ? error : 0;
    return out->status;
}
