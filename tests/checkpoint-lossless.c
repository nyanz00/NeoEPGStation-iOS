/* Execute the exact C APIs shipped in the app, with Matroska-shaped packets. */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include "NeoCheckpointLab.h"
static uint32_t le32(const uint8_t *p) {return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
static int cancel(void *p) {return *(int*)p;}
int main(int argc,char **argv) {
    if(argc!=6)return 2;
    FILE *f=fopen(argv[1],"rb");if(!f)return 3;uint8_t h[32];
    if(fread(h,1,32,f)!=32 || memcmp(h,"DKIF",4))return 4;
    NeoCheckpointPacket *packets=calloc(3000,sizeof(*packets));size_t count=0;double origin=0;
    while(count<3000) {
        uint8_t ph[12];if(fread(ph,1,12,f)!=12)break;size_t n=le32(ph);
        if(!n || n>64*1024*1024)return 5;uint8_t *data=malloc(n);
        if(!data || fread(data,1,n,f)!=n)return 6;
        if(n>=2 && data[0]==0x12 && data[1]==0) {memmove(data,data+2,n-2);n-=2;}
        uint64_t pts=le32(ph+4)|(uint64_t)le32(ph+8)<<32;double seconds=(double)pts*le32(h+20)/le32(h+16);
        if(!count)origin=seconds;packets[count++]=(NeoCheckpointPacket){data,n,seconds-origin};
    }
    fclose(f);double gop=strtod(argv[2],NULL),distance=strtod(argv[5],NULL);int method=atoi(argv[4]),stop=0,error=0;
    if(!strcmp(argv[3],"storage")) {
        NeoStorageResult out;
        int code=neo_checkpoint_storage_run(packets,count,gop,distance,method,&out,cancel,&stop);
        NeoCheckpointResult *r=&out.checkpoint;
        printf("{\"kind\":\"storage\",\"method\":%d,\"status\":%d,\"stage\":%d,\"decoderError\":%d,\"bytes\":%llu,\"restoreCount\":%d,\"targets\":%d,\"saveMs\":[",method,code,r->failure_stage,r->decoder_error,(unsigned long long)r->retained_bytes,r->restore_count,r->target_verified_count);
        for(int j=0;j<5;j++)printf("%s%.5f",j?",":"",r->repeated_save_ms[j]);printf("]}\n");
        error=code || r->restore_count!=5 || r->target_verified_count!=5 || r->full_suffix_passes!=2 || r->allocation_verification_passes!=2 || !r->original_pixels_detached || !r->empty_rejected || !r->busy_rejected || !r->wrong_owner_rejected;
        stop=1;if(neo_checkpoint_storage_run(packets,count,gop,distance,method,&out,cancel,&stop)!=1006)error=1;
    } else {
        NeoRealtimeResult r;
        int code=neo_checkpoint_realtime_run(packets,count,gop,method,&r,cancel,&stop);
        printf("{\"kind\":\"paced\",\"method\":%d,\"status\":%d,\"decoderError\":%d,\"frames\":%d,\"saves\":%d,\"retained\":%d,\"evicted\":%d,\"bytes\":%llu,\"lateFrames\":%d,\"lateP95\":%.5f,\"targets\":%d,\"used\":[%d,%d,%d]}\n",method,code,r.decoder_error,r.frames,r.completed_saves,r.retained_count,r.evicted,(unsigned long long)r.retained_bytes,r.late_frames,r.late_p95_ms,r.target_verified_count,r.used_checkpoint[0],r.used_checkpoint[1],r.used_checkpoint[2]);
        error=code || r.frames<=0 || r.target_verified_count!=3 || r.maximum_retained_bytes>r.memory_budget_bytes || (method>=0 && r.completed_saves<=0) || (method<0 && r.completed_saves!=0);
        stop=1;if(neo_checkpoint_realtime_run(packets,count,gop,method,&r,cancel,&stop)!=1006)error=1;
    }
    for(size_t j=0;j<count;j++)free((void*)packets[j].data);free(packets);return error?1:0;
}
