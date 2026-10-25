/* PC feasibility harness. Full row-by-row Y/U/V memcmp against an independent
 * decoder started normally at packet zero; never just a timestamp/hash check.
 * The independent decoder is a TEST ORACLE, not a parked seek decoder. */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <math.h>
#include <windows.h>
#include "dav1d/dav1d.h"
#include "neo_checkpoint.h"

typedef struct Packet { uint8_t *data; size_t size; uint64_t pts; } Packet;
typedef struct Input { Packet *p; size_t count; uint32_t rate, scale; } Input;
typedef struct Pictures { Dav1dPicture p[32]; unsigned count; } Pictures;
static uint64_t compared_frames, compared_bytes, suffix_keyframes;
static uint64_t first_suffix_key_pts = UINT64_MAX;
static double now(void) {
    LARGE_INTEGER t, f; QueryPerformanceCounter(&t); QueryPerformanceFrequency(&f);
    return (double)t.QuadPart / (double)f.QuadPart;
}
static void fail(const char *reason, int code) {
    fprintf(stderr, "probe: %s (%d)\n", reason, code); exit(1);
}
static void check(int condition, const char *reason) { if (!condition) fail(reason, 0); }
static uint32_t u32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1]<<8 | (uint32_t)p[2]<<16 | (uint32_t)p[3]<<24; }
static uint64_t u64(const uint8_t *p) { return (uint64_t)u32(p) | (uint64_t)u32(p+4)<<32; }
static Input input_open(const char *path) {
    FILE *f = fopen(path, "rb"); if (!f) fail("open IVF", errno);
    uint8_t h[32]; check(fread(h,1,32,f)==32 && !memcmp(h,"DKIF",4) && !memcmp(h+8,"AV01",4), "IVF AV1 header");
    check(h[6]==32 && h[7]==0, "IVF header size");
    Input in={0}; in.rate=u32(h+16); in.scale=u32(h+20); check(in.rate && in.scale, "IVF timebase");
    size_t total=0;
    for (;;) {
        uint8_t ph[12]; size_t n=fread(ph,1,12,f); if (!n && feof(f)) break;
        check(n==12, "truncated packet header");
        size_t size=u32(ph); total+=size;
        check(size && size<64*1024*1024 && total<256*1024*1024 && in.count<10000, "input budget");
        Packet *p=realloc(in.p,(in.count+1)*sizeof(*p)); check(p!=NULL,"packet allocation"); in.p=p;
        p=&in.p[in.count++]; p->size=size; p->pts=u64(ph+4); p->data=malloc(size); check(p->data!=NULL,"payload allocation");
        check(fread(p->data,1,size,f)==size,"truncated payload");
    }
    fclose(f); return in;
}
static double seconds(const Input *in, size_t i) { return (double)in->p[i].pts*in->scale/in->rate; }
static size_t index_at(const Input *in, double t) {
    for (size_t i=0;i<in->count;i++) if (seconds(in,i)>=t) return i;
    fail("requested position outside sample",0); return 0;
}
static void quiet(void *cookie, const char *format, va_list args) { (void)cookie; (void)format; (void)args; }
static Dav1dContext *decoder(void) {
    Dav1dSettings settings; dav1d_default_settings(&settings);
    settings.n_threads=1; settings.max_frame_delay=1; settings.logger.callback=quiet;
    Dav1dContext *c=NULL; int r=dav1d_open(&c,&settings); if (r) fail("decoder open",r); return c;
}
static void release(Pictures *pics) { for (unsigned i=0;i<pics->count;i++) dav1d_picture_unref(&pics->p[i]); pics->count=0; }
static int drain(Dav1dContext *c, Pictures *pics) {
    for (;;) {
        Dav1dPicture p={0}; int r=dav1d_get_picture(c,&p);
        if (r==DAV1D_ERR(EAGAIN)) return 0;
        if (r) return r;
        check(pics->count<32,"output queue bound"); pics->p[pics->count++]=p;
    }
}
static int feed(Dav1dContext *c, const Packet *p, size_t index, Pictures *pics) {
    Dav1dData d={0}; uint8_t *buf=dav1d_data_create(&d,p->size); check(buf!=NULL,"data allocation");
    memcpy(buf,p->data,p->size); d.m.timestamp=(int64_t)p->pts; d.m.offset=(int64_t)index;
    int r=dav1d_send_data(c,&d);
    if (r==DAV1D_ERR(EAGAIN)) { r=drain(c,pics); if (!r) r=dav1d_send_data(c,&d); }
    dav1d_data_unref(&d);
    return r ? r : drain(c,pics);
}
static void discard_range(Dav1dContext *c, const Input *in, size_t begin, size_t end) {
    for (size_t i=begin;i<end;i++) {
        Pictures p={0}; int r=feed(c,&in->p[i],i,&p); if (r) fail("decode prefix",r); release(&p);
    }
}
static void compare(const Pictures *a, const Pictures *b) {
    check(a->count==b->count,"output count differs");
    for (unsigned i=0;i<a->count;i++) {
        const Dav1dPicture *p=&a->p[i], *q=&b->p[i];
        check(p->p.w==q->p.w && p->p.h==q->p.h && p->p.bpc==q->p.bpc && p->p.layout==q->p.layout,"picture format differs");
        check(p->m.timestamp==q->m.timestamp && p->m.offset==q->m.offset,"picture input mapping differs");
        check(p->frame_hdr->frame_type==q->frame_hdr->frame_type,"frame type differs");
        if (p->frame_hdr->frame_type==DAV1D_FRAME_TYPE_KEY) {
            suffix_keyframes++;
            if (first_suffix_key_pts==UINT64_MAX) first_suffix_key_pts=(uint64_t)p->m.timestamp;
        }
        const int chroma=p->p.layout!=DAV1D_PIXEL_LAYOUT_I400;
        const int hsub=p->p.layout!=DAV1D_PIXEL_LAYOUT_I444, vsub=p->p.layout==DAV1D_PIXEL_LAYOUT_I420;
        for (int plane=0;plane<(chroma?3:1);plane++) {
            int w=plane ? (p->p.w+((1<<hsub)-1))>>hsub : p->p.w;
            int h=plane ? (p->p.h+((1<<vsub)-1))>>vsub : p->p.h;
            size_t bytes=(size_t)w*(p->p.bpc>8?2:1);
            for (int y=0;y<h;y++) {
                const uint8_t *x=(const uint8_t *)p->data[plane]+y*p->stride[plane?1:0];
                const uint8_t *z=(const uint8_t *)q->data[plane]+y*q->stride[plane?1:0];
                if (memcmp(x,z,bytes)) fail("pixel mismatch",(int)p->m.timestamp);
                compared_bytes+=bytes;
            }
        }
        compared_frames++;
    }
}
static void compare_range(Dav1dContext *reference, Dav1dContext *tested, const Input *in, size_t from, size_t to) {
    for (size_t i=from;i<to;i++) {
        Pictures a={0},b={0}; int r=feed(reference,&in->p[i],i,&a); if (r) fail("reference suffix",r);
        r=feed(tested,&in->p[i],i,&b); if (r) fail("restored suffix",r);
        compare(&a,&b); release(&a); release(&b);
    }
}
static double timed_target(Dav1dContext *c,const Input *in,size_t from,size_t to,uint64_t *frame_pts) {
    const double start=now(); int found=0;
    for (size_t i=from;i<=to;i++) {
        Pictures p={0}; int r=feed(c,&in->p[i],i,&p); if (r) fail("timed decode",r);
        for (unsigned j=0;j<p.count;j++) if (p.p[j].m.timestamp >= (int64_t)in->p[to].pts) {
            *frame_pts=(uint64_t)p.p[j].m.timestamp; found=1;
        }
        release(&p);
    }
    const double ms=(now()-start)*1000;
    check(found,"timed target has no output"); return ms;
}
int main(int argc,char **argv) {
    if (argc!=5) { fprintf(stderr,"usage: checkpoint-probe INPUT.ivf CHECKPOINT_SECONDS TARGET_SECONDS END_SECONDS\n"); return 2; }
    Input in=input_open(argv[1]);
    size_t cp_index=index_at(&in,strtod(argv[2],NULL)), target=index_at(&in,strtod(argv[3],NULL)), end=index_at(&in,strtod(argv[4],NULL));
    check(cp_index>0 && cp_index<target && target<end,"position order");
    Dav1dContext *c=decoder(), *original=c, *reference=decoder(); NeoCheckpoint *saved=NULL;
    /* Rejection guards: no sequence header yet, and a wrong destination. */
    check(neo_checkpoint_save(c,&saved)<0 && !saved,"empty decoder accepted");
    discard_range(c,&in,0,cp_index); discard_range(reference,&in,0,cp_index);
    double start=now(); int r=neo_checkpoint_save(c,&saved); double save_ms=(now()-start)*1000;
    if (r) fail("checkpoint save",r);
    check(neo_checkpoint_restore(reference,saved)<0,"cross-decoder restore accepted");
    NeoCheckpointStats stats; neo_checkpoint_stats(saved,&stats);
    /* Keeping a checkpoint must not change continued normal decoding. */
    compare_range(reference,c,&in,cp_index,end); dav1d_close(&reference);
    double restore_ms[5],seek_ms[5],full_ms[5],warm_ms[5]; uint64_t frame_pts=0;
    for (int k=0;k<5;k++) {
        reference=decoder(); discard_range(reference,&in,0,cp_index);
        start=now(); r=neo_checkpoint_restore(c,saved); restore_ms[k]=(now()-start)*1000;
        if (r) fail("checkpoint restore",r);
        check(c==original,"decoder replaced");
        compare_range(reference,c,&in,cp_index,end); dav1d_close(&reference);
    }
    /* Negative control: flush without state, then start at the same non-key
     * packet. A genuine random-access restart must not silently pass here. */
    Dav1dContext *negative=decoder(); Pictures neg={0};
    int negative_error=feed(negative,&in.p[cp_index],cp_index,&neg);
    check(negative_error<0 || neg.count==0,"negative control unexpectedly produced a picture");
    release(&neg); dav1d_close(&negative);
    for (int k=0;k<5;k++) {
        reference=decoder(); full_ms[k]=timed_target(reference,&in,0,target,&frame_pts); dav1d_close(&reference);
        dav1d_flush(c);
        warm_ms[k]=timed_target(c,&in,0,target,&frame_pts);
        start=now(); r=neo_checkpoint_restore(c,saved); if (r) fail("timed restore",r);
        timed_target(c,&in,cp_index,target,&frame_pts); seek_ms[k]=(now()-start)*1000;
    }
    check(suffix_keyframes>0,"sample did not cross a true keyframe after checkpoint");
    /* Free snapshots after owner teardown as well: retained memory pools must
     * remain valid until the last retained reference is released. */
    dav1d_close(&c); neo_checkpoint_free(&saved); check(!saved,"free did not clear handle");
    printf("{\"success\":true,\"dav1dVersion\":\"%s\",\"threads\":1,\"frameDelay\":1,",dav1d_version());
    printf("\"checkpointPacket\":%zu,\"checkpointSeconds\":%.6f,\"targetSeconds\":%.6f,\"endSeconds\":%.6f,",cp_index,seconds(&in,cp_index),seconds(&in,target),seconds(&in,end));
    printf("\"comparedFrames\":%llu,\"comparedPixelBytes\":%llu,\"sameDecoder\":true,\"negativeControlRejected\":true,",(unsigned long long)compared_frames,(unsigned long long)compared_bytes);
    printf("\"crossedKeyframe\":true,\"firstSuffixKeyframeSeconds\":%.6f,",(double)first_suffix_key_pts*in.scale/in.rate);
    printf("\"saveMs\":%.6f,\"stateBytes\":%zu,\"retainedBytes\":%zu,\"pictureBytes\":%zu,\"uniquePictures\":%u,\"uniqueAllocations\":%u,",save_ms,stats.state_bytes,stats.retained_bytes,stats.picture_bytes,stats.unique_pictures,stats.unique_allocations);
    printf("\"restoreMs\":["); for(int k=0;k<5;k++) printf("%s%.6f",k?",":"",restore_ms[k]);
    printf("],\"restoreAndSuffixMs\":["); for(int k=0;k<5;k++) printf("%s%.6f",k?",":"",seek_ms[k]);
    printf("],\"fromKeyframeMs\":["); for(int k=0;k<5;k++) printf("%s%.6f",k?",":"",full_ms[k]); printf("],\"warmFromKeyframeMs\":[");
    for(int k=0;k<5;k++) printf("%s%.6f",k?",":"",warm_ms[k]);
    printf("]}\n");
    for(size_t i=0;i<in.count;i++) free(in.p[i].data);
    free(in.p); return 0;
}
