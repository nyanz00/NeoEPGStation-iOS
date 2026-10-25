/* Host runner for the exact app C entry point, not a substitute implementation. */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include "NeoCheckpointLab.h"
static uint32_t u32(const uint8_t *p) {return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
static int cancelled(void *p) {return *(int*)p;}
int main(int argc,char **argv) {
    if(argc!=4) return 2;
    FILE *f=fopen(argv[1],"rb"); if(!f) return 3;
    uint8_t h[32]; if(fread(h,1,32,f)!=32 || memcmp(h,"DKIF",4)) return 4;
    NeoCheckpointPacket *input=calloc(3000,sizeof(*input)); if(!input) return 5;
    size_t count=0; double origin=0;
    while(count<3000) {
        uint8_t ph[12]; if(fread(ph,1,12,f)!=12) break;
        size_t n=u32(ph); if(!n || n>64*1024*1024) return 6;
        uint8_t *data=malloc(n); if(!data || fread(data,1,n,f)!=n) return 7;
        /* IVF muxing inserts an optional AV1 temporal delimiter. Matroska
         * AVPackets do not have it; exercise that same raw app input shape. */
        if(n>=2 && data[0]==0x12 && data[1]==0) {memmove(data,data+2,n-2);n-=2;}
        uint64_t pts=(uint64_t)u32(ph+4)|(uint64_t)u32(ph+8)<<32;
        double seconds=(double)pts*u32(h+20)/u32(h+16);
        if(!count) origin=seconds;
        input[count++]=(NeoCheckpointPacket){data,n,seconds-origin};
    }
    fclose(f); int cancel=0; NeoCheckpointResult r;
    int code=neo_checkpoint_lab_run(input,count,strtod(argv[2],NULL),strtod(argv[3],NULL),&r,cancelled,&cancel);
    printf("{\"status\":%d,\"decoderError\":%d,\"comparedFrames\":%llu,\"retainedBytes\":%llu,\"restoreCount\":%d,\"checkpointSeconds\":%.6f,\"targetSeconds\":%.6f,\"followingKeySeconds\":%.6f,\"baselineMs\":[",code,r.decoder_error,(unsigned long long)r.compared_frames,(unsigned long long)r.retained_bytes,r.restore_count,r.checkpoint_seconds,r.target_seconds,r.first_following_key_seconds);
    for(int i=0;i<5;i++) printf("%s%.6f",i?",":"",r.baseline_ms[i]);
    printf("],\"restoredMs\":[");
    for(int i=0;i<5;i++) printf("%s%.6f",i?",":"",r.restored_ms[i]);
    printf("]}\n");
    int failed=code || r.restore_count!=5 || r.temporary_save_free_count!=5 || !r.empty_rejected || !r.wrong_owner_rejected || !r.suffix_without_state_rejected || r.compared_frames<50;
    cancel=1;
    if(neo_checkpoint_lab_run(input,count,strtod(argv[2],NULL),.25,&r,cancelled,&cancel)!=1006) failed=1;
    if(neo_checkpoint_lab_run(input,count,0,.25,&r,NULL,NULL)!=1001) failed=1;
    for(size_t i=0;i<count;i++) free((void*)input[i].data);
    free(input); return failed ? 1 : 0;
}
