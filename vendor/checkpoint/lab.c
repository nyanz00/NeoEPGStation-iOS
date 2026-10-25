/* BSD-2-Clause. Bounded diagnostic only; never normal playback. */
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
#include "src/internal.h"
#include "packed.h"
#include "NeoCheckpointLab.h"

typedef struct Pictures { Dav1dPicture p[32]; unsigned count; } Pictures;
typedef struct State { NeoCheckpoint *raw; NeoPackedCheckpoint *packed; } State;
typedef struct Run {
    const NeoCheckpointPacket *packets;
    size_t count, cp, target;
    double began;
    int (*cancelled)(void *);
    void *cookie;
    NeoCheckpointResult *result;
    Dav1dPicture golden;
} Run;
typedef int (*Output)(Run *, void *, Dav1dPicture *);
static double now(void) {
#ifdef _WIN32
    LARGE_INTEGER t,f; QueryPerformanceCounter(&t); QueryPerformanceFrequency(&f);
    return (double)t.QuadPart/f.QuadPart;
#else
    struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t);
    return t.tv_sec+t.tv_nsec*1e-9;
#endif
}
uint64_t neo_checkpoint_lab_footprint(void) {
#ifdef __APPLE__
    task_vm_info_data_t info; mach_msg_type_number_t n=TASK_VM_INFO_COUNT;
    if(task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&info,&n)==KERN_SUCCESS)
        return info.phys_footprint;
#endif
    return 0;
}
static uint64_t sample(Run *r) {
    uint64_t n=neo_checkpoint_lab_footprint();
    if(n>r->result->sampled_peak_bytes) r->result->sampled_peak_bytes=n;
    return n;
}
static int check(Run *r) {
    if(r->cancelled && r->cancelled(r->cookie)) return 1006;
    return now()-r->began>180 ? 1007 : 0;
}
static void quiet(void *p,const char *s,va_list args) {(void)p;(void)s;(void)args;}
static int open_decoder(Dav1dContext **out,int threads,int *fc) {
    Dav1dSettings s; dav1d_default_settings(&s);
    s.n_threads=threads; s.max_frame_delay=threads==1?1:0;
    s.frame_size_limit=1920*1080; s.logger.callback=quiet;
    if(fc) *fc=dav1d_get_frame_delay(&s);
    return dav1d_open(out,&s);
}
static void state_free(State *s) {neo_checkpoint_free(&s->raw);neo_packed_free(&s->packed);}
static int state_save(Run *r,Dav1dContext *c,State *s) {
    return r->result->packed?neo_packed_save(c,&s->packed):neo_checkpoint_save(c,&s->raw);
}
static int state_restore(Run *r,Dav1dContext *c,State *s) {
    return r->result->packed?neo_packed_restore(c,s->packed):neo_checkpoint_restore(c,s->raw);
}
static int allocation_verify(Run *r,Dav1dContext *c,State *s) {
    if(!r->result->packed) return 0;
    int e=neo_packed_verify_buffers(c,s->packed);
    if(!e) r->result->allocation_verification_passes++;
    return e;
}
static void release(Pictures *p) {
    for(unsigned i=0;i<p->count;i++) dav1d_picture_unref(&p->p[i]);
    p->count=0;
}
static int ignore(Run *r,void *cookie,Dav1dPicture *p) {(void)r;(void)cookie;(void)p;return 0;}
static int take(Run *r,Dav1dContext *c,Output cb,void *cookie) {
    Dav1dPicture pic={0}; int e=dav1d_get_picture(c,&pic);
    if(!e) {e=cb(r,cookie,&pic);dav1d_picture_unref(&pic);}
    return e;
}
static int finish(Run *r,Dav1dContext *c,Output cb,void *cookie) {
    for(;;) {
        int e=check(r);if(e)return e;
        e=take(r,c,cb,cookie);if(e==DAV1D_ERR(EAGAIN))return 0;if(e)return e;
    }
}
static int feed(Run *r,Dav1dContext *c,size_t index,Output cb,void *cookie) {
    int e=check(r);if(e)return e;
    const NeoCheckpointPacket *src=&r->packets[index];
    Dav1dData data={0};uint8_t *bytes=dav1d_data_create(&data,src->size);
    if(!bytes)return DAV1D_ERR(ENOMEM);
    memcpy(bytes,src->data,src->size);
    data.m.timestamp=(int64_t)index;data.m.offset=(int64_t)index;
    unsigned tries=0;
    while(data.sz) {
        if((e=check(r)))break;
        if(++tries>1024) {e=1008;break;}
        e=dav1d_send_data(c,&data);
        if(e && e!=DAV1D_ERR(EAGAIN))break;
        /* Offer the next packet after ONE receive attempt. Repeated draining
         * here would serialize the frame-thread pipeline being measured. */
        e=take(r,c,cb,cookie);
        if(e==DAV1D_ERR(EAGAIN))e=0;
        if(e)break;
    }
    dav1d_data_unref(&data);return e;
}
static int advance(Run *r,Dav1dContext *c,size_t from,size_t end) {
    for(size_t i=from;i<end;i++) {int e=feed(r,c,i,ignore,NULL);if(e)return e;}
    return finish(r,c,ignore,NULL);
}
static int compare(Run *r,const Dav1dPicture *p,const Dav1dPicture *q) {
    if(p->p.w!=q->p.w || p->p.h!=q->p.h || p->p.bpc!=q->p.bpc ||
       p->p.layout!=q->p.layout || p->m.timestamp!=q->m.timestamp ||
       p->m.offset!=q->m.offset || p->frame_hdr->frame_type!=q->frame_hdr->frame_type)
        return 1003;
    if(p->m.timestamp<0 || (uint64_t)p->m.timestamp>=r->count)return 1003;
    r->result->width=p->p.w;r->result->height=p->p.h;r->result->bit_depth=p->p.bpc;
    if(p->frame_hdr->frame_type==DAV1D_FRAME_TYPE_KEY && r->result->first_following_key_seconds<0)
        r->result->first_following_key_seconds=r->packets[p->m.timestamp].seconds;
    int chroma=p->p.layout!=DAV1D_PIXEL_LAYOUT_I400;
    int hs=p->p.layout!=DAV1D_PIXEL_LAYOUT_I444,vs=p->p.layout==DAV1D_PIXEL_LAYOUT_I420;
    for(int plane=0;plane<(chroma?3:1);plane++) {
        int w=plane?(p->p.w+((1<<hs)-1))>>hs:p->p.w;
        int h=plane?(p->p.h+((1<<vs)-1))>>vs:p->p.h;
        size_t bytes=(size_t)w*(p->p.bpc>8?2:1);
        for(int y=0;y<h;y++) {
            const uint8_t *a=(const uint8_t*)p->data[plane]+y*p->stride[plane?1:0];
            const uint8_t *b=(const uint8_t*)q->data[plane]+y*q->stride[plane?1:0];
            if(memcmp(a,b,bytes))return 1003;
            r->result->compared_pixel_bytes+=bytes;
        }
    }
    r->result->compared_frames++;return 0;
}
typedef struct Match {Pictures a,b;int side; } Match;
static int verify_output(Run *r,void *cookie,Dav1dPicture *p) {
    Match *m=cookie;
    if(p->m.timestamp<(int64_t)r->cp || (uint64_t)p->m.timestamp>=r->count)return 1003;
    if(!m->side && p->m.timestamp==(int64_t)r->target && !r->golden.data[0])
        dav1d_picture_ref(&r->golden,p);
    Pictures *q=m->side?&m->b:&m->a;
    if(q->count==32)return 1005;
    q->p[q->count++]=*p;memset(p,0,sizeof(*p));
    while(m->a.count && m->b.count) {
        int e=compare(r,&m->a.p[0],&m->b.p[0]);if(e)return e;
        dav1d_picture_unref(&m->a.p[0]);dav1d_picture_unref(&m->b.p[0]);
        m->a.count--;m->b.count--;
        memmove(m->a.p,m->a.p+1,m->a.count*sizeof(m->a.p[0]));
        memmove(m->b.p,m->b.p+1,m->b.count*sizeof(m->b.p[0]));
    }
    return 0;
}
static int suffix(Run *r,Dav1dContext *tested) {
    Dav1dContext *oracle=NULL;Match m={0};int e=open_decoder(&oracle,1,NULL);
    if(e)goto done;
    e=advance(r,oracle,0,r->cp);if(e)goto done;
    for(size_t i=r->cp;i<r->count;i++) {
        m.side=0;e=feed(r,oracle,i,verify_output,&m);if(e)goto done;
        m.side=1;e=feed(r,tested,i,verify_output,&m);if(e)goto done;
    }
    m.side=0;e=finish(r,oracle,verify_output,&m);if(e)goto done;
    m.side=1;e=finish(r,tested,verify_output,&m);if(e)goto done;
    if(m.a.count || m.b.count) {e=1003;goto done;}
    r->result->full_suffix_passes++;sample(r);
done:
    release(&m.a);release(&m.b);if(oracle)dav1d_close(&oracle);return e;
}
typedef struct Timing {double began,ms;Dav1dPicture picture;} Timing;
static int timed_output(Run *r,void *cookie,Dav1dPicture *p) {
    Timing *t=cookie;
    if(p->m.timestamp<(int64_t)r->cp || p->m.timestamp>(int64_t)r->target)return 1003;
    if(p->m.timestamp==(int64_t)r->target && !t->picture.data[0]) {
        t->ms=(now()-t->began)*1000; /* before references/pixel checks */
        t->picture=*p;memset(p,0,sizeof(*p));
    }
    return 0;
}
static int reject_busy(Run *r,int threads) {
    Dav1dContext *c=NULL;State s={0};Dav1dData d={0};
    int e=open_decoder(&c,threads,NULL);if(e)goto done;
    uint8_t *p=dav1d_data_create(&d,r->packets[0].size);
    if(!p) {e=DAV1D_ERR(ENOMEM);goto done;}
    memcpy(p,r->packets[0].data,r->packets[0].size);
    e=dav1d_send_data(c,&d);if(e)goto done;
    r->result->busy_rejected=state_save(r,c,&s)<0;
    if(!r->result->busy_rejected)e=1002;
done:
    dav1d_data_unref(&d);state_free(&s);if(c)dav1d_close(&c);return e;
}
#define TRY(call) do {error=(call);if(error)goto done;} while(0)
int neo_checkpoint_lab_run(const NeoCheckpointPacket *packets,size_t count,
    double gop,double distance,int threads,int packed,NeoCheckpointResult *out,
    int(*cancelled)(void*),void *cookie) {
    if(!out)return 1001;
    memset(out,0,sizeof(*out));out->first_following_key_seconds=-1;
    out->threads=threads;out->packed=packed;
    Run r={0};r.packets=packets;r.count=count;r.began=now();r.cancelled=cancelled;r.cookie=cookie;r.result=out;
    Dav1dContext *c=NULL,*negative=NULL;State saved={0},temporary={0};Timing t={0};
    int error=0;size_t total=0;
    out->before_bytes=sample(&r);out->failure_stage=1;
    if(!packets || count<4 || count>3000 || !isfinite(gop) || gop<=.5 || gop>65 ||
       !isfinite(distance) || distance<=0 || (threads!=1 && threads!=2 && threads!=4 && threads!=6) ||
       (packed!=0 && packed!=1)) {error=1001;goto done;}
    for(size_t i=0;i<count;i++) {
        if(!packets[i].data || !packets[i].size || packets[i].size>64*1024*1024 ||
           !isfinite(packets[i].seconds) || (i && packets[i].seconds<packets[i-1].seconds)) {error=1001;goto done;}
        total+=packets[i].size;if(total>96*1024*1024) {error=1005;goto done;}
    }
    TRY(check(&r));TRY(neo_packed_codec_selftest());
    double wanted=gop*.9,position=wanted-fmin(distance,wanted*.5);
    while(r.cp<count && packets[r.cp].seconds<position)r.cp++;
    while(r.target<count && packets[r.target].seconds<wanted)r.target++;
    if(!r.cp || r.cp>=r.target || r.target>=count) {error=1001;goto done;}
    out->checkpoint_seconds=packets[r.cp].seconds;out->target_seconds=packets[r.target].seconds;
    TRY(open_decoder(&c,threads,&out->frame_contexts));
    out->empty_rejected=state_save(&r,c,&temporary)<0 && !temporary.raw && !temporary.packed;
    if(!out->empty_rejected) {error=1002;goto done;}
    out->failure_stage=2;
    for(size_t i=0;i<r.cp;i++)TRY(feed(&r,c,i,ignore,NULL));
    double began=now();TRY(finish(&r,c,ignore,NULL));out->drain_before_save_ms=(now()-began)*1000;
    out->failure_stage=3;began=now();TRY(state_save(&r,c,&saved));out->save_ms=(now()-began)*1000;
    if(packed) {
        NeoPackedStats s;neo_packed_stats(saved.packed,&s);
        out->retained_bytes=s.total_bytes;out->state_bytes=s.state_bytes+s.metadata_bytes;
        out->picture_bytes=s.pixel_bytes;out->unique_pictures=s.unique_pictures;
        out->original_pixels_detached=s.pixel_references_detached;
        if(!out->original_pixels_detached) {error=1002;goto done;}
    } else {
        NeoCheckpointStats s;neo_checkpoint_stats(saved.raw,&s);
        out->retained_bytes=s.retained_bytes;out->state_bytes=s.state_bytes;
        out->picture_bytes=s.picture_bytes;out->unique_pictures=s.unique_pictures;
    }
    if(out->retained_bytes>96*1024*1024) {error=1005;goto done;}
    TRY(allocation_verify(&r,c,&saved));
    for(int k=0;k<NEO_CHECKPOINT_REPEATS;k++) {
        TRY(check(&r));began=now();TRY(state_save(&r,c,&temporary));
        out->repeated_save_ms[k]=(now()-began)*1000;state_free(&temporary);out->temporary_save_free_count++;
    }
    out->failure_stage=6;TRY(open_decoder(&negative,threads,NULL));
    out->wrong_owner_rejected=state_restore(&r,negative,&saved)<0;
    if(!out->wrong_owner_rejected) {error=1002;goto done;}
    dav1d_close(&negative);TRY(reject_busy(&r,threads));
    TRY(open_decoder(&negative,threads,NULL));
    { int e=feed(&r,negative,r.cp,ignore,NULL);
      out->suffix_without_state_rejected=e<0;
      if(!e) {Dav1dPicture p={0};e=dav1d_get_picture(negative,&p);
          out->suffix_without_state_rejected=e==DAV1D_ERR(EAGAIN) || e<0;dav1d_picture_unref(&p);}
      if(!out->suffix_without_state_rejected) {error=1002;goto done;} }
    dav1d_close(&negative);
    out->failure_stage=4;TRY(suffix(&r,c));
    TRY(state_restore(&r,c,&saved));TRY(allocation_verify(&r,c,&saved));TRY(suffix(&r,c));
    if(!r.golden.data[0] || out->first_following_key_seconds<=wanted) {error=1004;goto done;}
    out->failure_stage=5;
    for(int k=0;k<NEO_CHECKPOINT_REPEATS;k++) {
        TRY(check(&r));memset(&t,0,sizeof(t));t.began=now();
        TRY(state_restore(&r,c,&saved));out->restore_only_ms[k]=(now()-t.began)*1000;
        out->restore_count++;
        for(size_t i=r.cp;i<=r.target;i++)TRY(feed(&r,c,i,timed_output,&t));
        TRY(finish(&r,c,timed_output,&t));
        if(!t.picture.data[0]) {error=1004;goto done;}
        out->restored_ms[k]=t.ms;TRY(compare(&r,&r.golden,&t.picture));out->target_verified_count++;
        dav1d_picture_unref(&t.picture);
        out->sampled_footprint_bytes[k]=sample(&r);
        TRY(advance(&r,c,r.target+1,count));
    }
    out->failure_stage=0;
done:
    dav1d_picture_unref(&t.picture);dav1d_picture_unref(&r.golden);
    if(negative)dav1d_close(&negative);
    if(c)dav1d_close(&c);
    state_free(&temporary);state_free(&saved);
    out->after_bytes=neo_checkpoint_lab_footprint();
    out->status=error<0?1008:error;out->decoder_error=error<0?error:0;
    return out->status;
}
