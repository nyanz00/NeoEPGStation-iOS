/* Reuse the original immutable-input / full-pixel oracle, without changing it. */
#define main neo_original_probe_unused
#include "../dav1d-checkpoint/probe.c"
#undef main
#include "packed.h"

typedef struct Phase {
    size_t held, pixels, meta;
    unsigned pictures;
    int detached;
    double save[5], destroy[5], restore[5], target[5];
    uint64_t frames, bytes;
} Phase;
static void restore(Dav1dContext *c,int packed,NeoCheckpoint *raw,NeoPackedCheckpoint *small) {
    int r=packed?neo_packed_restore(c,small):neo_checkpoint_restore(c,raw);
    if(r) fail("state restore",r);
}
static Phase phase(const Input *in,size_t cp,size_t target,size_t end,int packed) {
    Phase result={0};
    Dav1dContext *c=decoder(),*oracle=NULL;
    NeoCheckpoint *raw=NULL;
    NeoPackedCheckpoint *small=NULL;
    compared_frames=compared_bytes=suffix_keyframes=0;first_suffix_key_pts=UINT64_MAX;
    discard_range(c,in,0,cp);
    int r=packed?neo_packed_save(c,&small):neo_checkpoint_save(c,&raw);
    if(r)fail("initial save",r);
    if(packed) {
        NeoPackedStats stats;neo_packed_stats(small,&stats);
        result.held=stats.total_bytes;result.pixels=stats.pixel_bytes;
        result.meta=stats.state_bytes+stats.metadata_bytes;result.pictures=stats.unique_pictures;
        result.detached=stats.pixel_references_detached;
        check(result.detached,"packed state still retains original pixel buffers");
        check(!neo_packed_verify_buffers(c,small),"packed save changed pixel or padding bytes");
        Dav1dContext *wrong=decoder();
        check(neo_packed_restore(wrong,small)<0,"packed wrong owner accepted");dav1d_close(&wrong);
    } else {
        NeoCheckpointStats stats;neo_checkpoint_stats(raw,&stats);
        result.held=stats.retained_bytes;result.pixels=stats.picture_bytes;
        result.meta=stats.retained_bytes-stats.picture_bytes;result.pictures=stats.unique_pictures;
    }
    /* Saving must leave ordinary decoding unaffected. Then every restoration
     * starts AFTER advancing through a real later keyframe. */
    oracle=decoder();discard_range(oracle,in,0,cp);
    compare_range(oracle,c,in,cp,end);dav1d_close(&oracle);
    for(int k=0;k<5;k++) {
        restore(c,packed,raw,small);
        if(packed)check(!neo_packed_verify_buffers(c,small),"restored allocation bytes differ");
        NeoCheckpoint *tmp_raw=NULL;NeoPackedCheckpoint *tmp_small=NULL;
        double start=now();
        r=packed?neo_packed_save(c,&tmp_small):neo_checkpoint_save(c,&tmp_raw);
        result.save[k]=(now()-start)*1000;if(r)fail("repeated save",r);
        start=now();
        if(packed)neo_packed_free(&tmp_small);else neo_checkpoint_free(&tmp_raw);
        result.destroy[k]=(now()-start)*1000;
        oracle=decoder();discard_range(oracle,in,0,cp);
        compare_range(oracle,c,in,cp,end);dav1d_close(&oracle);
        start=now();restore(c,packed,raw,small);
        result.restore[k]=(now()-start)*1000;
        uint64_t pts=0;timed_target(c,in,cp,target,&pts);
        result.target[k]=(now()-start)*1000;
        /* Advance again, so even timing repeats restore over stale/new GOP
         * state rather than immediately restoring an identical decoder. */
        discard_range(c,in,target+1,end);
    }
    check(suffix_keyframes>0,"did not verify across a later real keyframe");
    result.frames=compared_frames;result.bytes=compared_bytes;
    dav1d_close(&c);
    if(packed)neo_packed_free(&small);else neo_checkpoint_free(&raw);
    check(!small && !raw,"state not freed after owner teardown");
    return result;
}
static void array(const char *key,const double *a) {
    printf(",\"%s\":[",key);
    for(int k=0;k<5;k++)printf("%s%.6f",k?",":"",a[k]);
    printf("]");
}
static void print_phase(const char *name,const Phase *p) {
    printf("\"%s\":{\"heldBytes\":%zu,\"pixelBytes\":%zu,\"metadataAndStateBytes\":%zu,\"uniquePictures\":%u,\"originalPixelReferencesDetached\":%s,\"fullPixelComparedFrames\":%llu,\"fullPixelComparedBytes\":%llu",name,p->held,p->pixels,p->meta,p->pictures,p->detached?"true":"false",(unsigned long long)p->frames,(unsigned long long)p->bytes);
    array("saveMs",p->save);array("freeMs",p->destroy);array("restoreMs",p->restore);array("restoreAndSuffixMs",p->target);
    printf("}");
}
int main(int argc,char **argv) {
    if(argc!=5)return 2;
    DWORD_PTR allowed=0,system=0,old=0,chosen=0;
    if(GetProcessAffinityMask(GetCurrentProcess(),&allowed,&system)) {
        chosen=allowed&(~allowed+1);old=SetThreadAffinityMask(GetCurrentThread(),chosen);
    }
    check(!neo_packed_codec_selftest(),"10bit codec self-test failed");
    Dav1dContext *empty=decoder();NeoPackedCheckpoint *none=NULL;
    check(neo_packed_save(empty,&none)<0 && !none,"empty decoder accepted");dav1d_close(&empty);
    Input in=input_open(argv[1]);
    size_t cp=index_at(&in,strtod(argv[2],NULL)),target=index_at(&in,strtod(argv[3],NULL)),end=index_at(&in,strtod(argv[4],NULL));
    check(cp>0 && cp<target && target<end,"point ordering");
    Phase raw=phase(&in,cp,target,end,0),small=phase(&in,cp,target,end,1);
    check(raw.frames==small.frames && raw.bytes==small.bytes,"oracle coverage differs");
    printf("{\"success\":true,\"singleThread\":true,\"threadAffinityPinned\":%s,\"affinityMask\":%llu,\"checkpointSeconds\":%.6f,\"targetSeconds\":%.6f,\"endSeconds\":%.6f,\"allAllocationBytesVerified\":true,\"crossedRealKeyframe\":true,\"sameDecoderPerPhase\":true,\"selfTestWidths\":257,",old?"true":"false",(unsigned long long)chosen,seconds(&in,cp),seconds(&in,target),seconds(&in,end));
    print_phase("unpacked",&raw);printf(",");print_phase("packed",&small);printf("}\n");
    for(size_t i=0;i<in.count;i++)free(in.p[i].data);
    free(in.p);if(old)SetThreadAffinityMask(GetCurrentThread(),old);return 0;
}
