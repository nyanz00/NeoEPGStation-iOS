/* Uses the proven streaming feeder and full-pixel comparison, not app UI. */
#include "neo_storage_base.h"
#include "storage.h"
typedef struct Captured {size_t index;Dav1dPicture picture;} Captured;
typedef struct TargetTime {Timing t;Dav1dPicture picture;} TargetTime;
static void get_golden(void *cookie,Dav1dPicture *p) {
    Captured *g=cookie;if(p->m.offset==(int64_t)g->index) {check(!g->picture.data[0],"duplicate golden");g->picture=*p;memset(p,0,sizeof(*p));}
}
static void get_timed(void *cookie,Dav1dPicture *p) {
    TargetTime *t=cookie;timed_output(&t->t,p);
    if(p->m.offset==(int64_t)t->t.end) {t->picture=*p;memset(p,0,sizeof(*p));}
}
static double target_at(Context *c,const Input *in,size_t cp,size_t target,const Captured *gold) {
    TargetTime t={0};t.t.in=in;t.t.begin=cp;t.t.end=target;t.t.start_cpu=cpu_ms();t.t.start=now();
    for(size_t i=cp;i<=target;i++)submit(c,in,i,get_timed,&t);
    finish(c,get_timed,&t);check(t.t.found && t.picture.data[0],"target missing");
    Pictures a={0},b={0};a.count=b.count=1;a.p[0]=gold->picture;b.p[0]=t.picture;compare(&a,&b);
    dav1d_picture_unref(&t.picture);return t.t.wall;
}
static void recipe_prefix(Context *c,const Input *in,NeoRecipe *r) {
    neo_recipe_start(r,c->c);
    for(size_t j=0;j<neo_recipe_count(r);j++) {
        size_t n;int64_t index;const uint8_t *bytes=neo_recipe_packet(r,j,&n,&index);
        if(!n)continue;
        Packet packet={0};packet.data=(uint8_t*)bytes;packet.size=n;packet.pts=in->p[index].pts;
        Input view=*in;view.p=&packet;
        /* Feed copies the input; preserve original index by using a temporary
         * array view, with only this borrowed packet replaced. */
        Packet old=in->p[index];in->p[index]=packet;submit(c,in,(size_t)index,ignore,NULL);in->p[index]=old;
        (void)view;
    }
    finish(c,ignore,NULL);neo_recipe_stop(r);
}
int main(int argc,char **argv) {
    if(argc!=7)return 2;
    DWORD_PTR affinity=choose_cores();Input in=input_open(argv[1]);
    size_t cp=index_at(&in,strtod(argv[2],NULL)),target=index_at(&in,strtod(argv[3],NULL)),
           end=index_at(&in,strtod(argv[4],NULL)),key=index_at(&in,strtod(argv[5],NULL));
    int run_compress=atoi(argv[6]);check(key<cp && cp<target && target<end,"point order");
    Config config={6,0};Context owner=open_context(config),oracle=open_context((Config){1,1});
    Captured golden={0};golden.index=target;
    for(size_t j=0;j<=target;j++)submit(&oracle,&in,j,get_golden,&golden);
    finish(&oracle,get_golden,&golden);dav1d_close(&oracle.c);check(golden.picture.data[0]!=NULL,"golden absent");
    NeoTrace *trace=neo_trace_start(owner.c);check(trace!=NULL,"trace allocate");prefix(&owner,&in,cp);neo_trace_stop(trace);
    NeoRecipe *recipe=neo_recipe_build(trace,cp);check(recipe!=NULL,"recipe build");neo_trace_free(&trace);
    State saved={0};require(state_save(&owner,&saved,1),"base checkpoint");
    NeoPackedStats base;neo_packed_stats(saved.packed,&base);
    size_t held,payload,selected,original;neo_recipe_stats(recipe,&held,&payload,&selected,&original);
    printf("{\"success\":true,\"threads\":6,\"frameContexts\":%d,\"affinityMask\":%llu,\"checkpointSeconds\":%.6f,\"targetSeconds\":%.6f,\"endSeconds\":%.6f,\"keySeconds\":%.6f,\"baselineBytes\":%zu,\"baselinePixelBytes\":%zu,\"compression\":[",owner.frame_contexts,(unsigned long long)affinity,seconds(&in,cp),seconds(&in,target),seconds(&in,end),seconds(&in,key),base.total_bytes,base.pixel_bytes);
    if(run_compress)for(int m=0;m<NEO_STORAGE_METHODS;m++) {
        require(state_restore(&owner,&saved,1),"restore before compression");NeoStorageMetrics out;
        require(neo_storage_measure(owner.c,m,&out),"compression save/restore");
        check(out.detached && out.verified==NEO_STORAGE_REPEATS,"compression verification count");
        uint64_t before=compared_frames;suffix_verify(&owner,&in,cp,end);
        printf("%s{\"method\":\"%s\",\"heldBytes\":%zu,\"pixelBytes\":%zu,\"originalPixelsDetached\":true,\"allocationByteVerifications\":%d,\"suffixComparedFrames\":%llu,\"saveMs\":[",m?",":"",neo_storage_method(m),out.held_bytes,out.pixel_bytes,out.verified,(unsigned long long)(compared_frames-before));
        for(int j=0;j<NEO_STORAGE_REPEATS;j++)printf("%s%.6f",j?",":"",out.save_ms[j]);
        printf("],\"restoreMs\":[");for(int j=0;j<NEO_STORAGE_REPEATS;j++)printf("%s%.6f",j?",":"",out.restore_ms[j]);printf("]}");fflush(stdout);
        fprintf(stderr,"Compression and exact suffix passed: %s\n",neo_storage_method(m));
    }
    require(state_restore(&owner,&saved,1),"restore owner references");
    Context replay=open_context(config),full=open_context(config);
    recipe_prefix(&replay,&in,recipe);
    require(neo_recipe_verify_refs(owner.c,replay.c),"recipe reference pixels mismatch");
    uint64_t before=compared_frames;suffix_verify(&replay,&in,cp,end);
    uint64_t suffix_frames=compared_frames-before;
    /* Warm normal decoder workspace, then measure nearest real-key restart. */
    advance(&full,&in,0,end);
    double prefix_ms[3][5]={{0}},seek_ms[3][5]={{0}};
    for(int rep=0;rep<5;rep++)for(int n=0;n<3;n++) {
        int mode=(n+rep)%3;Context *c=mode==0?&full:mode==1?&replay:&owner;
        double began=now();
        if(mode==0) {dav1d_flush(c->c);advance(c,&in,key,cp);}
        else if(mode==1) {dav1d_flush(c->c);recipe_prefix(c,&in,recipe);}
        else require(state_restore(c,&saved,1),"timed packed restore");
        prefix_ms[mode][rep]=(now()-began)*1000;
        require(neo_recipe_verify_refs(owner.c,c->c),"timed reference mismatch");
        seek_ms[mode][rep]=prefix_ms[mode][rep]+target_at(c,&in,cp,target,&golden);
        /* Owner must represent the checkpoint for the next comparison. */
        if(mode==2)require(state_restore(&owner,&saved,1),"restore owner after target");
    }
    printf("],\"recipe\":{\"heldBytes\":%zu,\"compressedPayloadAndHeadersBytes\":%zu,\"selectedCodedFrames\":%zu,\"originalCodedFrames\":%zu,\"headerDependencyClosure\":true,\"traceFreedBeforeReplay\":true,\"allEightReferenceSlotsVerified\":true,\"suffixComparedFrames\":%llu",held,payload,selected,original,(unsigned long long)suffix_frames);
    values("rebuildMs",prefix_ms[1]);values("rebuildAndTargetMs",seek_ms[1]);
    values("keyToCheckpointMs",prefix_ms[0]);values("keyToTargetMs",seek_ms[0]);
    values("packedRestoreMs",prefix_ms[2]);values("packedRestoreAndTargetMs",seek_ms[2]);
    printf("},\"comparedFrames\":%llu,\"comparedBytes\":%llu}\n",(unsigned long long)compared_frames,(unsigned long long)compared_bytes);
    neo_recipe_free(&recipe);state_free(&saved);dav1d_close(&owner.c);dav1d_close(&replay.c);dav1d_close(&full.c);
    dav1d_picture_unref(&golden.picture);for(size_t j=0;j<in.count;j++)free(in.p[j].data);free(in.p);return 0;
}
