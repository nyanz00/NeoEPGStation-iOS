/* Reuse only the input reader and full-pixel comparison oracle. The old
 * per-packet drain loop is NOT used: it serializes frame-thread pipelines. */
#define main neo_legacy_probe_unused
#include "../dav1d-checkpoint/probe.c"
#undef main

typedef void (*Output)(void *,Dav1dPicture *);
typedef struct Context {
    Dav1dContext *c;
    int frame_contexts;
} Context;
typedef struct Config {int threads,delay;} Config;
typedef struct Trial {
    double wall[5],cpu[5],prefix[5],init[5];
    int fc;
    uint64_t verified_frames,verified_bytes;
} Trial;

static double cpu_ms(void) {
    FILETIME creation,exit,kernel,user;
    check(GetProcessTimes(GetCurrentProcess(),&creation,&exit,&kernel,&user),"process CPU timer");
    ULARGE_INTEGER k={0},u={0};
    k.LowPart=kernel.dwLowDateTime;k.HighPart=kernel.dwHighDateTime;
    u.LowPart=user.dwLowDateTime;u.HighPart=user.dwHighDateTime;
    return (k.QuadPart+u.QuadPart)/10000.0;
}
static Context open_context(Config config) {
    Dav1dSettings s;dav1d_default_settings(&s);
    s.n_threads=config.threads;s.max_frame_delay=config.delay;s.logger.callback=quiet;
    Context ctx={0};ctx.frame_contexts=dav1d_get_frame_delay(&s);
    int r=dav1d_open(&ctx.c,&s);if(r)fail("parallel decoder open",r);
    return ctx;
}
static int take(Context *ctx,Output callback,void *cookie) {
    Dav1dPicture p={0};int r=dav1d_get_picture(ctx->c,&p);
    if(!r) {callback(cookie,&p);dav1d_picture_unref(&p);}
    return r;
}
static void ignore(void *cookie,Dav1dPicture *p) {(void)cookie;(void)p;}
static void submit(Context *ctx,const Input *in,size_t index,Output cb,void *cookie) {
    const Packet *p=&in->p[index];Dav1dData data={0};
    uint8_t *bytes=dav1d_data_create(&data,p->size);check(bytes!=NULL,"packet allocate");
    memcpy(bytes,p->data,p->size);data.m.timestamp=(int64_t)p->pts;data.m.offset=(int64_t)index;
    unsigned tries=0;
    while(data.sz) {
        check(++tries<1024,"decoder made no input progress");
        int r=dav1d_send_data(ctx->c,&data);
        if(r && r!=DAV1D_ERR(EAGAIN))fail("send",r);
        /* One receive attempt per send. Offer the next packet before trying
         * to drain repeatedly, preserving normal frame-thread overlap. */
        r=take(ctx,cb,cookie);
        if(r && r!=DAV1D_ERR(EAGAIN))fail("receive",r);
    }
    dav1d_data_unref(&data);
}
static void finish(Context *ctx,Output cb,void *cookie) {
    /* Last submit already attempted get_picture once, setting drain=1.
     * Drain the segment fully; no prefix work may overlap the timed segment. */
    for(;;) {int r=take(ctx,cb,cookie);if(r==DAV1D_ERR(EAGAIN))break;if(r)fail("segment drain",r);}
}
static void prefix(Context *ctx,const Input *in,size_t end) {
    for(size_t i=0;i<end;i++)submit(ctx,in,i,ignore,NULL);
    finish(ctx,ignore,NULL);
}
typedef struct Timing {
    const Input *in;
    size_t begin,end;
    double start,start_cpu,wall,cpu;
    unsigned frames;
    int found;
} Timing;
static void timed_output(void *cookie,Dav1dPicture *p) {
    Timing *t=cookie;
    check(p->m.offset>=(int64_t)t->begin && p->m.offset<=(int64_t)t->end,"output outside timed segment");
    t->frames++;
    if(!t->found && p->m.timestamp>=(int64_t)t->in->p[t->end].pts) {
        t->wall=(now()-t->start)*1000;t->cpu=cpu_ms()-t->start_cpu;t->found=1;
        check(p->m.timestamp==(int64_t)t->in->p[t->end].pts,"target PTS differs");
    }
}
static void measure(const Input *in,size_t begin,size_t end,Config config,Trial *out,int rep) {
    double start=now();Context ctx=open_context(config);out->init[rep]=(now()-start)*1000;
    out->fc=ctx.frame_contexts;start=now();prefix(&ctx,in,begin);out->prefix[rep]=(now()-start)*1000;
    Timing t={0};t.in=in;t.begin=begin;t.end=end;
    t.start_cpu=cpu_ms();t.start=now();
    for(size_t i=begin;i<=end;i++)submit(&ctx,in,i,timed_output,&t);
    finish(&ctx,timed_output,&t);
    check(t.found && t.frames,"timed target not returned");
    out->wall[rep]=t.wall;out->cpu[rep]=t.cpu;
    dav1d_close(&ctx.c);
}
typedef struct Match {
    Pictures a,b;
    size_t begin,end;
} Match;
static void match(Match *m) {
    while(m->a.count && m->b.count) {
        Pictures a={0},b={0};a.count=b.count=1;a.p[0]=m->a.p[0];b.p[0]=m->b.p[0];
        compare(&a,&b);release(&a);release(&b);
        m->a.count--;m->b.count--;
        memmove(m->a.p,m->a.p+1,m->a.count*sizeof(m->a.p[0]));
        memmove(m->b.p,m->b.p+1,m->b.count*sizeof(m->b.p[0]));
    }
}
typedef struct Side {Match *m;int which;} Side;
static void verify_output(void *cookie,Dav1dPicture *p) {
    Side *s=cookie;Match *m=s->m;
    check(p->m.offset>=(int64_t)m->begin && p->m.offset<=(int64_t)m->end,"verification output outside segment");
    Pictures *q=s->which?&m->b:&m->a;
    check(q->count<32,"verification queue overflow");
    q->p[q->count++]=*p;memset(p,0,sizeof(*p));match(m);
}
static void verify(const Input *in,size_t begin,size_t end,Config config,Trial *out) {
    Context reference=open_context((Config){1,1}),tested=open_context(config);
    prefix(&reference,in,begin);prefix(&tested,in,begin);
    compared_frames=compared_bytes=0;
    Match m={0};m.begin=begin;m.end=end;Side a={&m,0},b={&m,1};
    for(size_t i=begin;i<=end;i++) {
        submit(&reference,in,i,verify_output,&a);submit(&tested,in,i,verify_output,&b);
    }
    finish(&reference,verify_output,&a);finish(&tested,verify_output,&b);match(&m);
    check(!m.a.count && !m.b.count && compared_frames>0,"verification output count differs");
    out->verified_frames=compared_frames;out->verified_bytes=compared_bytes;
    dav1d_close(&reference.c);dav1d_close(&tested.c);
}
static DWORD_PTR choose_cores(void) {
    DWORD_PTR allowed=0,system=0;check(GetProcessAffinityMask(GetCurrentProcess(),&allowed,&system),"affinity read");
    DWORD size=0;GetLogicalProcessorInformationEx(RelationProcessorCore,NULL,&size);
    uint8_t *buf=malloc(size);check(buf!=NULL,"topology allocate");
    check(GetLogicalProcessorInformationEx(RelationProcessorCore,(void*)buf,&size),"physical core topology");
    DWORD_PTR mask=0;unsigned count=0;
    for(DWORD offset=0;offset<size;) {
        SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX *info=(void*)(buf+offset);
        check(info->Size>0,"invalid topology entry");
        if(info->Processor.GroupCount==1 && info->Processor.GroupMask[0].Group==0 && count<6) {
            DWORD_PTR core=info->Processor.GroupMask[0].Mask&allowed;
            if(core) {mask|=core&(~core+1);count++;}
        }
        offset+=info->Size;
    }
    free(buf);check(count==6,"need six available physical cores in one group");
    check(SetProcessAffinityMask(GetCurrentProcess(),mask),"process core selection");
    check(SetThreadAffinityMask(GetCurrentThread(),mask)!=0,"main-thread core selection");
    return mask;
}
static void values(const char *key,const double *p) {
    printf(",\"%s\":[",key);for(int i=0;i<5;i++)printf("%s%.6f",i?",":"",p[i]);printf("]");
}
int main(int argc,char **argv) {
    if(argc!=4)return 2;
    DWORD_PTR mask=choose_cores();Input in=input_open(argv[1]);
    size_t begin=index_at(&in,strtod(argv[2],NULL)),end=index_at(&in,strtod(argv[3],NULL));
    check(begin>0 && begin<end,"segment order");
    Config configs[7]={{1,1},{2,1},{4,1},{6,1},{2,0},{4,0},{6,0}};Trial rows[7]={0};
    for(int i=0;i<7;i++)verify(&in,begin,end,configs[i],&rows[i]);
    /* Rotate settings across repetitions rather than always measuring one
     * thread count first. Image comparison never runs in these timers. */
    for(int rep=0;rep<5;rep++)for(int k=0;k<7;k++) {
        int i=(k+rep*3)%7;measure(&in,begin,end,configs[i],&rows[i],rep);
    }
    printf("{\"success\":true,\"checkpointUsed\":false,\"frameSkipping\":false,\"affinityMask\":%llu,\"physicalCoresAvailable\":6,\"prefixFullyDrained\":true,\"startSeconds\":%.6f,\"targetSeconds\":%.6f,\"rows\":[",(unsigned long long)mask,seconds(&in,begin),seconds(&in,end));
    for(int i=0;i<7;i++) {
        Trial *r=&rows[i];
        printf("%s{\"threads\":%d,\"maxFrameDelaySetting\":%d,\"frameContexts\":%d,\"fullPixelComparedFrames\":%llu,\"fullPixelComparedBytes\":%llu",i?",":"",configs[i].threads,configs[i].delay,r->fc,(unsigned long long)r->verified_frames,(unsigned long long)r->verified_bytes);
        values("targetMs",r->wall);values("processCpuMs",r->cpu);values("prefixMs",r->prefix);values("initializeMs",r->init);printf("}");
    }
    printf("]}\n");for(size_t i=0;i<in.count;i++)free(in.p[i].data);free(in.p);return 0;
}
