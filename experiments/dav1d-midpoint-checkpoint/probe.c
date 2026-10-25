/* PC-only matched A/B: random access from a real keyframe vs a losslessly
 * packed midpoint checkpoint. Existing streaming feed and full-pixel oracle. */
#include "neo_midpoint_base.h"

#define TARGETS 6
#define REPEATS 5
#define MAX_GOPS 20
typedef struct Point {
    size_t index;
    double fraction, baseline[REPEATS], assisted[REPEATS], periodic[REPEATS];
    Dav1dPicture golden;
} Point;
typedef struct Capture {Point *points;} Capture;
typedef struct Arrival {Timing timing; Dav1dPicture picture;} Arrival;
typedef struct Saved {
    State state;
    size_t key, midpoint, next;
    size_t held;
    double save_ms, drain_ms;
} Saved;
static void capture_points(void *cookie,Dav1dPicture *p) {
    Capture *c=cookie;
    for(int i=0;i<TARGETS;i++) if(p->m.offset==(int64_t)c->points[i].index) {
        check(!c->points[i].golden.data[0],"duplicate golden target");
        c->points[i].golden=*p;memset(p,0,sizeof(*p));break;
    }
}
static void arrival(void *cookie,Dav1dPicture *p) {
    Arrival *a=cookie;timed_output(&a->timing,p);
    if(p->m.offset==(int64_t)a->timing.end) {
        check(!a->picture.data[0],"duplicate timed target");
        a->picture=*p;memset(p,0,sizeof(*p));
    }
}
static double seek_target(Context *ctx,const Input *in,Saved *s,Point *point,int assisted) {
    Arrival a={0};a.timing.in=in;a.timing.end=point->index;
    const int use=assisted && point->index>=s->midpoint;
    size_t from=use?s->midpoint:s->key;
    a.timing.begin=from;a.timing.start_cpu=cpu_ms();a.timing.start=now();
    if(use) require(state_restore(ctx,&s->state,1),"midpoint timed restore");
    else dav1d_flush(ctx->c);
    for(size_t i=from;i<=point->index;i++)submit(ctx,in,i,arrival,&a);
    finish(ctx,arrival,&a);
    check(a.timing.found && a.picture.data[0],"timed target absent");
    Pictures gold={0},actual={0};gold.count=actual.count=1;
    gold.p[0]=point->golden;actual.p[0]=a.picture;
    compare(&gold,&actual); /* all Y/U/V bytes, outside the arrival timer */
    dav1d_picture_unref(&a.picture);
    return a.timing.wall;
}
int main(int argc,char **argv) {
    if(argc!=4)return 2;
    DWORD_PTR affinity=choose_cores();Input in=input_open(argv[1]);
    FILE *f=fopen(argv[2],"r");check(f!=NULL,"key index input");
    size_t keys[MAX_GOPS+1],gops=0;
    while(gops<MAX_GOPS+1 && fscanf(f,"%zu",&keys[gops])==1)gops++;
    fclose(f);check(gops>=2 && gops<=MAX_GOPS+1,"keyframe count");gops--;
    int threads=atoi(argv[3]);check(threads==6,"six-thread experiment");
    Config config={threads,0};Context tested=open_context(config),baseline=open_context(config),periodic=open_context(config);
    Saved saved[MAX_GOPS]={0};size_t previous=0,total_held=0;
    require(neo_packed_codec_selftest(),"packing self-test");
    for(size_t g=0;g<gops;g++) {
        Saved *s=&saved[g];s->key=keys[g];s->next=keys[g+1];
        check(s->key<s->next && s->next<in.count,"keyframe range");
        double middle=(seconds(&in,s->key)+seconds(&in,s->next))*.5;
        s->midpoint=index_at(&in,middle);
        check(s->key<s->midpoint && s->midpoint<s->next,"midpoint range");
        for(size_t i=previous;i<s->midpoint;i++)submit(&tested,&in,i,ignore,NULL);
        double began=now();finish(&tested,ignore,NULL);s->drain_ms=(now()-began)*1000;
        began=now();require(state_save(&tested,&s->state,1),"save midpoint");s->save_ms=(now()-began)*1000;
        NeoPackedStats stats;neo_packed_stats(s->state.packed,&stats);
        check(stats.pixel_references_detached,"original pixels retained");
        s->held=stats.total_bytes;total_held+=s->held;
        require(neo_packed_verify_buffers(tested.c,s->state.packed),"packed full allocation mismatch");
        previous=s->midpoint;
    }
    Saved fixed[MAX_GOPS]={0};size_t fixed_count=0,fixed_held=0,fixed_previous=0;
    for(double at=6;at<seconds(&in,keys[gops]);at+=6) {
        check(fixed_count<MAX_GOPS,"periodic checkpoint budget");Saved *s=&fixed[fixed_count++];
        s->midpoint=index_at(&in,at);
        for(size_t i=fixed_previous;i<s->midpoint;i++)submit(&periodic,&in,i,ignore,NULL);
        double began=now();finish(&periodic,ignore,NULL);s->drain_ms=(now()-began)*1000;
        began=now();require(state_save(&periodic,&s->state,1),"save periodic");s->save_ms=(now()-began)*1000;
        NeoPackedStats stats;neo_packed_stats(s->state.packed,&stats);
        check(stats.pixel_references_detached,"periodic original pixels retained");
        s->held=stats.total_bytes;fixed_held+=s->held;
        require(neo_packed_verify_buffers(periodic.c,s->state.packed),"periodic allocation mismatch");
        fixed_previous=s->midpoint;
    }
    /* Both reusable decoders have normal allocated workspaces before timing.
     * Only tested owns snapshots. No decoder is parked per saved position. */
    advance(&tested,&in,previous,in.count);advance(&baseline,&in,0,in.count);
    advance(&periodic,&in,fixed_previous,in.count);
    Context oracle=open_context((Config){1,1});previous=0;
    uint64_t before=compared_frames;double fractions[TARGETS]={.1,.4,.51,.75,.95,.99};
    printf("{\"success\":true,\"threads\":%d,\"frameContexts\":%d,\"affinityMask\":%llu,\"checkpointCount\":%zu,\"totalCheckpointBytes\":%zu,\"periodicCheckpointCount\":%zu,\"periodicCheckpointBytes\":%zu,\"rows\":[",threads,tested.frame_contexts,(unsigned long long)affinity,gops,total_held,fixed_count,fixed_held);
    int printed=0;
    for(size_t g=0;g<gops;g++) {
        Saved *s=&saved[g];Point points[TARGETS]={0};Capture cap={points};
        double start=seconds(&in,s->key),end=seconds(&in,s->next);
        for(int j=0;j<TARGETS;j++) {
            points[j].fraction=fractions[j];points[j].index=index_at(&in,start+(end-start)*fractions[j]);
            /* VFR can leave no picture between the requested 99% position and
             * the next key. Use the last actual packet in this GOP. */
            if(points[j].index>=s->next)points[j].index=s->next-1;
            check(points[j].index<s->next,"target crossed next key");
            if(j)check(points[j].index>points[j-1].index,"duplicate targets");
        }
        /* Six reference images at most; single-thread oracle is test-only and
         * continues normally across GOPs. Its work is outside all seek timers. */
        for(size_t i=previous;i<s->next;i++)submit(&oracle,&in,i,capture_points,&cap);
        finish(&oracle,capture_points,&cap);previous=s->next;
        for(int j=0;j<TARGETS;j++)check(points[j].golden.data[0]!=NULL,"golden target missing");
        for(int rep=0;rep<REPEATS;rep++)for(int n=0;n<TARGETS;n++) {
            int j=(n+rep*5+(int)g*3)%TARGETS;
            for(int k=0;k<3;k++) {
                int mode=(k+rep+j+(int)g)%3;
                if(mode==2) {
                    Saved selected={0};selected.key=s->key;selected.midpoint=SIZE_MAX;
                    for(size_t n=0;n<fixed_count;n++)if(fixed[n].midpoint>s->key && fixed[n].midpoint<=points[j].index) {
                        selected=fixed[n];selected.key=s->key;
                    }
                    points[j].periodic[rep]=seek_target(&periodic,&in,&selected,&points[j],1);
                } else {
                    Context *ctx=mode?&tested:&baseline;
                    double ms=seek_target(ctx,&in,s,&points[j],mode);
                    if(mode)points[j].assisted[rep]=ms;else points[j].baseline[rep]=ms;
                }
            }
        }
        for(int j=0;j<TARGETS;j++) {
            Point *p=&points[j];
            printf("%s{\"gop\":%zu,\"keySeconds\":%.6f,\"nextKeySeconds\":%.6f,\"midpointSeconds\":%.6f,\"targetSeconds\":%.6f,\"fraction\":%.2f,\"usesCheckpoint\":%s,\"heldBytes\":%zu,\"saveMs\":%.6f,\"drainBeforeSaveMs\":%.6f",printed++?",":"",g,start,end,seconds(&in,s->midpoint),seconds(&in,p->index),p->fraction,p->index>=s->midpoint?"true":"false",s->held,s->save_ms,s->drain_ms);
            values("fromKeyframeMs",p->baseline);values("withMidpointMs",p->assisted);values("periodicSixSecondsMs",p->periodic);printf("}");
            dav1d_picture_unref(&p->golden);
        }
        fprintf(stderr,"Matched A/B and exact pixels passed: GOP %zu/%zu\n",g+1,gops);fflush(stderr);
    }
    check(compared_frames-before==gops*TARGETS*REPEATS*3,"verification target count");
    printf("],\"fullPixelComparedFrames\":%llu,\"fullPixelComparedBytes\":%llu,\"allSnapshotsCoexisted\":true,\"originalPixelsDetached\":true,\"repeats\":%d,\"noFrameSkipping\":true}\n",(unsigned long long)(compared_frames-before),(unsigned long long)compared_bytes,REPEATS);
    /* Exercise freeing multiple states in reverse order after owner teardown. */
    dav1d_close(&tested.c);dav1d_close(&baseline.c);dav1d_close(&periodic.c);dav1d_close(&oracle.c);
    for(size_t g=gops;g>0;g--)state_free(&saved[g-1].state);
    for(size_t g=fixed_count;g>0;g--)state_free(&fixed[g-1].state);
    for(size_t i=0;i<in.count;i++)free(in.p[i].data);
    free(in.p);return 0;
}
