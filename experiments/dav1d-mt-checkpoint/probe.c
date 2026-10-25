/* Generated include reuses the verified streaming feeder and full-pixel oracle.
 * Neither former per-packet draining nor checkpoint timing shortcuts are used. */
#include "neo_parallel_harness.h"
#include "packed.h"

typedef struct State {
    NeoCheckpoint *raw;
    NeoPackedCheckpoint *packed;
} State;
typedef struct Result {
    size_t held;
    double save[5],restore[5],target[5];
    uint64_t frames,bytes;
    int busy_rejected,wrong_owner_rejected,detached;
} Result;
static void state_free(State *s) {neo_checkpoint_free(&s->raw);neo_packed_free(&s->packed);}
static int state_save(Context *c,State *s,int packed) {
    return packed?neo_packed_save(c->c,&s->packed):neo_checkpoint_save(c->c,&s->raw);
}
static int state_restore(Context *c,State *s,int packed) {
    return packed?neo_packed_restore(c->c,s->packed):neo_checkpoint_restore(c->c,s->raw);
}
static void require(int r,const char *message) {if(r)fail(message,r);}
static void suffix_verify(Context *c,const Input *in,size_t cp,size_t end) {
    Context oracle=open_context((Config){1,1});prefix(&oracle,in,cp);
    Match m={0};m.begin=cp;m.end=end-1;Side a={&m,0},b={&m,1};
    for(size_t i=cp;i<end;i++) {
        submit(&oracle,in,i,verify_output,&a);submit(c,in,i,verify_output,&b);
    }
    finish(&oracle,verify_output,&a);finish(c,verify_output,&b);match(&m);
    check(!m.a.count && !m.b.count,"restored output count mismatch");
    dav1d_close(&oracle.c);
}
static void advance(Context *c,const Input *in,size_t from,size_t end) {
    for(size_t i=from;i<end;i++)submit(c,in,i,ignore,NULL);
    finish(c,ignore,NULL);
}
static int reject_busy(const Input *in,Config config,int packed) {
    Context c=open_context(config);State s={0};Dav1dData d={0};
    uint8_t *p=dav1d_data_create(&d,in->p[0].size);check(p!=NULL,"busy input allocate");
    memcpy(p,in->p[0].data,in->p[0].size);d.m.timestamp=(int64_t)in->p[0].pts;
    require(dav1d_send_data(c.c,&d),"busy input send");dav1d_data_unref(&d);
    /* Deliberately do NOT receive/drain: pending output/work must be rejected,
     * rather than discarded or partly saved. */
    int rejected=state_save(&c,&s,packed)<0;
    state_free(&s);dav1d_close(&c.c);return rejected;
}
static Result phase(const Input *in,size_t cp,size_t target_index,size_t end,Config config,int packed) {
    Result out={0};out.busy_rejected=reject_busy(in,config,packed);
    check(out.busy_rejected,"in-flight checkpoint accepted");
    Context c=open_context(config);prefix(&c,in,cp);State state={0};
    require(state_save(&c,&state,packed),"initial MT save");
    if(packed) {
        NeoPackedStats s;neo_packed_stats(state.packed,&s);out.held=s.total_bytes;out.detached=s.pixel_references_detached;
        check(out.detached,"packed MT state retains original pixels");
        require(neo_packed_verify_buffers(c.c,state.packed),"packed MT buffer mismatch after save");
    } else {NeoCheckpointStats s;neo_checkpoint_stats(state.raw,&s);out.held=s.retained_bytes;}
    Context wrong=open_context(config);
    out.wrong_owner_rejected=state_restore(&wrong,&state,packed)<0;
    check(out.wrong_owner_rejected,"MT wrong owner accepted");dav1d_close(&wrong.c);
    compared_frames=compared_bytes=suffix_keyframes=0;first_suffix_key_pts=UINT64_MAX;
    suffix_verify(&c,in,cp,end);
    for(int k=0;k<5;k++) {
        require(state_restore(&c,&state,packed),"MT verification restore");
        if(packed)require(neo_packed_verify_buffers(c.c,state.packed),"packed MT allocation bytes mismatch");
        State temporary={0};double started=now();require(state_save(&c,&temporary,packed),"MT repeated save");
        out.save[k]=(now()-started)*1000;state_free(&temporary);
        suffix_verify(&c,in,cp,end);
        started=now();require(state_restore(&c,&state,packed),"MT timed restore");
        out.restore[k]=(now()-started)*1000;
        Timing t={0};t.in=in;t.begin=cp;t.end=target_index;t.start=started;t.start_cpu=cpu_ms();
        for(size_t i=cp;i<=target_index;i++)submit(&c,in,i,timed_output,&t);
        finish(&c,timed_output,&t);check(t.found,"restored target not returned");out.target[k]=t.wall;
        advance(&c,in,target_index+1,end);
    }
    check(suffix_keyframes>0,"MT restoration not verified across real keyframe");
    out.frames=compared_frames;out.bytes=compared_bytes;
    dav1d_close(&c.c);state_free(&state);
    return out;
}
typedef struct Golden {size_t index;Pictures target;} Golden;
static void capture(void *cookie,Dav1dPicture *p) {
    Golden *g=cookie;
    if(p->m.offset==(int64_t)g->index) {
        check(!g->target.count,"more than one golden target");g->target.p[0]=*p;g->target.count=1;memset(p,0,sizeof(*p));
    }
}
static void check_target(void *cookie,Dav1dPicture *p) {
    Golden *g=cookie;if(p->m.offset!=(int64_t)g->index)return;
    Pictures actual={0};actual.p[0]=*p;actual.count=1;compare(&g->target,&actual);
}
static unsigned multi_stress(const Input *in,size_t target_index,size_t end,Config config) {
    Golden gold={0};gold.index=target_index;Context reference=open_context((Config){1,1});
    for(size_t i=0;i<=target_index;i++)submit(&reference,in,i,capture,&gold);
    finish(&reference,capture,&gold);check(gold.target.count==1,"golden target missing");dav1d_close(&reference.c);
    size_t cp[3]={index_at(in,14),index_at(in,18),index_at(in,19.8)};
    State saved[3]={0};Context c=open_context(config);size_t previous=0;
    for(int i=0;i<3;i++) {advance(&c,in,previous,cp[i]);require(state_save(&c,&saved[i],1),"multi-point save");previous=cp[i];}
    advance(&c,in,previous,end);
    uint64_t before=compared_frames;
    /* Thirty seeks alternate old points after crossing a keyframe. One hundred
     * more repeat a close target to expose races in worker parking/progress. */
    for(int k=0;k<130;k++) {
        int point=k<30?(k*2)%3:2;
        require(state_restore(&c,&saved[point],1),"multi-point stress restore");
        for(size_t i=cp[point];i<=target_index;i++)submit(&c,in,i,check_target,&gold);
        finish(&c,check_target,&gold);
        if(k<30)advance(&c,in,target_index+1,end);
    }
    check(compared_frames-before==130,"stress target count differs");
    /* Free in a different order, including after owner teardown. */
    state_free(&saved[1]);dav1d_close(&c.c);state_free(&saved[2]);state_free(&saved[0]);release(&gold.target);
    return 130;
}
static void print_result(const char *name,const Result *r) {
    printf("\"%s\":{\"heldBytes\":%zu,\"busyRejected\":%s,\"wrongOwnerRejected\":%s,\"originalPixelsDetached\":%s,\"fullPixelComparedFrames\":%llu,\"fullPixelComparedBytes\":%llu",name,r->held,r->busy_rejected?"true":"false",r->wrong_owner_rejected?"true":"false",r->detached?"true":"false",(unsigned long long)r->frames,(unsigned long long)r->bytes);
    values("saveMs",r->save);values("restoreMs",r->restore);values("restoreAndSuffixMs",r->target);printf("}");
}
int main(int argc,char **argv) {
    if(argc!=7)return 2;
    DWORD_PTR mask=choose_cores();Input in=input_open(argv[1]);
    Config config={atoi(argv[2]),atoi(argv[3])};
    size_t cp=index_at(&in,strtod(argv[4],NULL)),target_index=index_at(&in,strtod(argv[5],NULL)),end=index_at(&in,strtod(argv[6],NULL));
    check(cp>0 && cp<target_index && target_index<end,"MT point order");
    require(neo_packed_codec_selftest(),"packing self-test");
    Result raw=phase(&in,cp,target_index,end,config,0),packed=phase(&in,cp,target_index,end,config,1);
    unsigned stress=config.threads==6 && cp==index_at(&in,19.8)?multi_stress(&in,target_index,end,config):0;
    Dav1dSettings settings;dav1d_default_settings(&settings);settings.n_threads=config.threads;settings.max_frame_delay=config.delay;
    printf("{\"success\":true,\"threads\":%d,\"frameContexts\":%d,\"affinityMask\":%llu,\"checkpointSeconds\":%.6f,\"targetSeconds\":%.6f,\"endSeconds\":%.6f,\"sameOwnerDecoder\":true,\"fullPipelineDrained\":true,\"crossedRealKeyframe\":true,\"multiPointStressTargets\":%u,",config.threads,dav1d_get_frame_delay(&settings),(unsigned long long)mask,seconds(&in,cp),seconds(&in,target_index),seconds(&in,end),stress);
    print_result("unpacked",&raw);printf(",");print_result("packed",&packed);printf("}\n");
    for(size_t i=0;i<in.count;i++)free(in.p[i].data);
    free(in.p);return 0;
}
