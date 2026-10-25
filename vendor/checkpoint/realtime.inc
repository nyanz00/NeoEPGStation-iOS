/* Paced decode diagnostic. No rendering or audio is included. Compression runs
 * on one utility worker while the existing six decoder workers continue. */
#ifdef __APPLE__
#include <sys/qos.h>
#endif
typedef struct Retained {NeoLosslessCheckpoint *state;double seconds;uint64_t bytes;} Retained;
typedef struct StorageWorker {
    pthread_mutex_t lock;pthread_cond_t condition;pthread_t thread;
    int active,stop,error,started;
    NeoLosslessCheckpoint *pending;double pending_seconds,capture_ms;
    Retained retained[NEO_REALTIME_MAX_SAVES];int count;
    NeoRealtimeResult *out;
} StorageWorker;
static void *compression_worker(void *cookie) {
    StorageWorker *w=cookie;
#ifdef __APPLE__
    pthread_set_qos_class_self_np(QOS_CLASS_UTILITY,0);
#endif
    for(;;) {
        pthread_mutex_lock(&w->lock);
        while(!w->pending && !w->stop)pthread_cond_wait(&w->condition,&w->lock);
        if(!w->pending && w->stop) {pthread_mutex_unlock(&w->lock);break;}
        NeoLosslessCheckpoint *state=w->pending;w->pending=NULL;
        double seconds=w->pending_seconds,capture=w->capture_ms;
        pthread_mutex_unlock(&w->lock);
        double cpu=storage_cpu_ms(),began=now();int e=neo_lossless_encode(state);
        double ms=(now()-began)*1000,after=storage_cpu_ms();NeoLosslessStats stats;neo_lossless_stats(state,&stats);
        pthread_mutex_lock(&w->lock);
        if(!e && (!stats.detached || stats.held_bytes>w->out->memory_budget_bytes))e=1005;
        if(!e && w->out->completed_saves>=NEO_REALTIME_MAX_SAVES)e=1005;
        if(!e) {
            int i=w->out->completed_saves++;
            w->out->save_ms[i]=ms;w->out->capture_ms[i]=capture;
            w->out->save_cpu_ms[i]=cpu>=0 && after>=cpu?after-cpu:-1;
            while(w->count && (w->out->retained_bytes+stats.held_bytes>w->out->memory_budget_bytes || w->count==NEO_REALTIME_MAX_SAVES)) {
                w->out->retained_bytes-=w->retained[0].bytes;neo_lossless_free(&w->retained[0].state);
                w->count--;memmove(w->retained,w->retained+1,(size_t)w->count*sizeof(w->retained[0]));w->out->evicted++;
            }
            w->retained[w->count++]=(Retained){state,seconds,stats.held_bytes};state=NULL;
            w->out->retained_bytes+=stats.held_bytes;
            if(w->out->retained_bytes>w->out->maximum_retained_bytes)w->out->maximum_retained_bytes=w->out->retained_bytes;
        }
        neo_lossless_free(&state);w->error=e;w->active=0;
        pthread_mutex_unlock(&w->lock);
    }
    return NULL;
}
static int worker_init(StorageWorker *w,NeoRealtimeResult *out) {
    memset(w,0,sizeof(*w));w->out=out;
    if(pthread_mutex_init(&w->lock,NULL))return 1008;
    if(pthread_cond_init(&w->condition,NULL)) {pthread_mutex_destroy(&w->lock);return 1008;}
    if(pthread_create(&w->thread,NULL,compression_worker,w)) {
        pthread_cond_destroy(&w->condition);pthread_mutex_destroy(&w->lock);return 1008;
    }
    w->started=1;return 0;
}
static void worker_join(StorageWorker *w) {
    if(!w->started)return;
    pthread_mutex_lock(&w->lock);w->stop=1;pthread_cond_signal(&w->condition);pthread_mutex_unlock(&w->lock);
    pthread_join(w->thread,NULL);w->started=0;
}
static void worker_free(StorageWorker *w) {
    worker_join(w);
    neo_lossless_free(&w->pending);
    for(int i=0;i<w->count;i++)neo_lossless_free(&w->retained[i].state);
    if(w->out) {pthread_cond_destroy(&w->condition);pthread_mutex_destroy(&w->lock);w->out=NULL;}
}
static void storage_pause(double seconds) {
    if(seconds<=0)return;
#ifdef _WIN32
    DWORD ms=(DWORD)(seconds*1000);Sleep(ms?ms:1);
#else
    struct timespec t={0};t.tv_nsec=(long)(seconds*1e9);nanosleep(&t,NULL);
#endif
}
typedef struct Pace {
    NeoRealtimeResult *out;
    double start,previous,late[3000];int n;
} Pace;
static int paced_output(Run *r,void *cookie,Dav1dPicture *p) {
    Pace *pace=cookie;
    if(p->m.timestamp<0 || (uint64_t)p->m.timestamp>=r->count)return 1003;
    double seconds=r->packets[p->m.timestamp].seconds,deadline=pace->start+seconds;
    double lateness=fmax(0,(now()-deadline)*1000);
    if(pace->n==3000)return 1005;
    double duration=pace->n?seconds-pace->previous:1.0/30;
    if(duration<=0 || duration>.25)duration=1.0/30;
    pace->late[pace->n++]=lateness;pace->out->frames++;
    if(lateness>duration*1000)pace->out->late_frames++;
    pace->previous=seconds;pace->out->media_seconds=seconds;
    while(now()<deadline) {int e=check(r);if(e)return e;storage_pause(fmin(.005,deadline-now()));}
    sample(r);return 0;
}
static int double_order(const void *a,const void *b) {
    double x=*(const double*)a,y=*(const double*)b;return (x>y)-(x<y);
}
static int build_golden(Run *r,size_t target,Dav1dPicture *gold) {
    Dav1dContext *oracle=NULL;int e=open_decoder(&oracle,1,NULL);if(e)return e;
    Run view=*r;view.cp=0;view.target=target;Timing t={0};t.began=now();
    for(size_t j=0;j<=target;j++) {e=feed(&view,oracle,j,timed_output,&t);if(e)break;}
    if(!e)e=finish(&view,oracle,timed_output,&t);
    dav1d_close(&oracle);
    if(e) {dav1d_picture_unref(&t.picture);return e;}
    if(!t.picture.data[0])return 1004;
    *gold=t.picture;return 0;
}
int neo_checkpoint_realtime_run(const NeoCheckpointPacket *packets,size_t count,double gop,int method,
    NeoRealtimeResult *out,int(*cancelled)(void*),void *cookie) {
    if(!out)return 1001;
    memset(out,0,sizeof(*out));out->method=method;out->memory_budget_bytes=64*1024*1024;
    NeoCheckpointResult observations={0};Run r={0};r.packets=packets;r.count=count;r.began=now();r.cancelled=cancelled;r.cookie=cookie;r.result=&observations;
    Dav1dContext *c=NULL;StorageWorker worker={0};Pace pace={0};pace.out=out;
    Dav1dPicture golden={0};Timing target_time={0};int error=0,worker_ready=0;
    out->before_bytes=sample(&r);TRY(storage_input(&r,gop));
    if(method!=-1 && method!=0 && method!=4 && method!=7) {error=1001;goto done;}
    TRY(open_decoder(&c,6,NULL));
    size_t warm=0,end=0;double until=fmin(gop*.9,24.0);
    while(warm<count && packets[warm].seconds<.5)warm++;
    while(end<count && packets[end].seconds<until)end++;
    if(warm>=end || end>=count) {error=1001;goto done;}
    TRY(advance(&r,c,0,warm));
    if(method>=0) {TRY(worker_init(&worker,out));worker_ready=1;}
    pace.start=now()-packets[warm].seconds;double next_save=2;
    for(size_t i=warm;i<end;i++) {
        TRY(feed(&r,c,i,paced_output,&pace));
        if(method>=0 && packets[i].seconds>=next_save) {
            TRY(finish(&r,c,paced_output,&pace));next_save+=2;
            pthread_mutex_lock(&worker.lock);int busy=worker.active,failed=worker.error;pthread_mutex_unlock(&worker.lock);
            if(failed) {error=failed;goto done;}
            if(busy) {out->skipped_busy++;continue;}
            NeoLosslessCheckpoint *state=NULL;double began=now();
            TRY(neo_lossless_capture(c,method,&state));double capture=(now()-began)*1000;
            pthread_mutex_lock(&worker.lock);worker.pending=state;worker.pending_seconds=packets[i+1].seconds;
            worker.capture_ms=capture;worker.active=1;pthread_cond_signal(&worker.condition);pthread_mutex_unlock(&worker.lock);
        }
    }
    TRY(finish(&r,c,paced_output,&pace));out->wall_seconds=now()-pace.start-packets[warm].seconds;
    if(worker_ready) {worker_join(&worker);if(worker.error) {error=worker.error;goto done;}}
    if(pace.n) {
        double sum=0;for(int j=0;j<pace.n;j++)sum+=pace.late[j];out->late_mean_ms=sum/pace.n;
        qsort(pace.late,(size_t)pace.n,sizeof(double),double_order);
        out->late_max_ms=pace.late[pace.n-1];out->late_p95_ms=pace.late[(pace.n-1)*95/100];
    }
    out->retained_count=worker.count;
    for(int k=0;k<NEO_REALTIME_TARGETS;k++) {
        double wanted=until*(k==0?.1:k==1?.5:.99);size_t target=0;
        while(target<count && packets[target].seconds<wanted)target++;
        if(target>=end)target=end-1;
        TRY(build_golden(&r,target,&golden));r.cp=0;r.target=target;
        Retained *chosen=NULL;
        for(int j=0;j<worker.count;j++)if(worker.retained[j].seconds<=packets[target].seconds)chosen=&worker.retained[j];
        memset(&target_time,0,sizeof(target_time));target_time.began=now();
        if(chosen) {
            TRY(neo_lossless_restore(c,chosen->state));
            while(r.cp<count && packets[r.cp].seconds<chosen->seconds)r.cp++;
            out->used_checkpoint[k]=1;out->chosen_seconds[k]=chosen->seconds;
        } else {dav1d_flush(c);out->chosen_seconds[k]=0;}
        for(size_t j=r.cp;j<=target;j++)TRY(feed(&r,c,j,timed_output,&target_time));
        TRY(finish(&r,c,timed_output,&target_time));
        if(!target_time.picture.data[0]) {error=1004;goto done;}
        out->target_ms[k]=target_time.ms;out->target_seconds[k]=packets[target].seconds;
        TRY(compare(&r,&golden,&target_time.picture));out->target_verified_count++;
        dav1d_picture_unref(&golden);dav1d_picture_unref(&target_time.picture);
    }
done:
    dav1d_picture_unref(&golden);dav1d_picture_unref(&target_time.picture);
    if(worker_ready)worker_free(&worker);
    if(c)dav1d_close(&c);
    out->sampled_peak_bytes=observations.sampled_peak_bytes;out->after_bytes=neo_checkpoint_lab_footprint();
    out->status=error<0?1008:error;out->decoder_error=error<0?error:0;return out->status;
}
