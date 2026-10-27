/* BSD-2-Clause. Real playback bridge: transfer from a CLOSED donor decoder,
 * decode the suffix, compare every output pixel against ordinary playback. */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include "NeoCheckpointPlayback.h"
typedef struct Packet {uint8_t *data;size_t size;int64_t pts;} Packet;
typedef struct Input {Packet *packets;size_t count;double tick;} Input;
static void need(int ok,const char *msg) {if(!ok) {fprintf(stderr,"%s\n",msg);exit(1);}}
static uint32_t u32(const uint8_t *p) {return p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
static Input load(const char *path) {
    FILE *f=fopen(path,"rb");need(f!=NULL,"open fixture");uint8_t h[32];
    need(fread(h,1,32,f)==32 && !memcmp(h,"DKIF",4),"IVF header");
    Input in={0};in.tick=(double)u32(h+20)/u32(h+16);
    while(1) {
        uint8_t row[12];size_t n=fread(row,1,12,f);if(!n)break;need(n==12,"packet header");
        in.packets=realloc(in.packets,(in.count+1)*sizeof(Packet));need(in.packets!=NULL,"packets");
        Packet *p=&in.packets[in.count++];p->size=u32(row);need(p->size && p->size<16000000,"packet size");
        p->pts=(int64_t)((uint64_t)u32(row+4)|(uint64_t)u32(row+8)<<32);
        p->data=malloc(p->size);need(p->data!=NULL,"payload");need(fread(p->data,1,p->size,f)==p->size,"packet payload");
    }
    fclose(f);return in;
}
typedef struct Image {uint8_t *pixels;size_t bytes;int64_t pts;int width,height,depth;} Image;
typedef struct Images {Image images[128];size_t count;} Images;
static void collect(void *cookie,const NeoAV1Frame *frame) {
    Images *list=cookie;need(list->count<128,"output bound");Image *im=&list->images[list->count++];
    im->pts=frame->timestamp;im->width=frame->width;im->height=frame->height;im->depth=frame->depth;
    size_t n=0;for(int pl=0;pl<3;pl++) {
        int w=pl?(frame->width+1)/2:frame->width,h=pl?(frame->height+1)/2:frame->height;
        n+=(size_t)w*h*(frame->depth>8?2:1);
    }
    im->pixels=malloc(n);need(im->pixels!=NULL,"oracle image");im->bytes=n;size_t cursor=0;
    for(int pl=0;pl<3;pl++) {
        int w=pl?(frame->width+1)/2:frame->width,h=pl?(frame->height+1)/2:frame->height;
        size_t row=(size_t)w*(frame->depth>8?2:1);
        for(int y=0;y<h;y++) {memcpy(im->pixels+cursor,frame->plane[pl]+y*frame->stride[pl!=0],row);cursor+=row;}
    }
}
static void feed(NeoAV1Playback *decoder,const Input *in,size_t index,Images *images) {
    const Packet *p=&in->packets[index];
    need(neo_av1_playback_feed(decoder,p->data,p->size,p->pts,1,(int64_t)index,
                              images?collect:NULL,images)==0,"playback packet feed");
}
static void clear(Images *images) {for(size_t i=0;i<images->count;i++)free(images->images[i].pixels);images->count=0;}
int main(int argc,char **argv) {
    if(argc!=3)return 2;Input in=load(argv[1]);double at=atof(argv[2]);
    size_t cp=0;while(cp<in.count && in.packets[cp].pts*in.tick<at)cp++;
    need(cp>0 && cp+32<in.count,"checkpoint inside fixture");
    NeoAV1Playback *donor=neo_av1_playback_open(42);need(donor!=NULL,"donor");
    for(size_t i=0;i<cp;i++)feed(donor,&in,i,NULL);
    need(!neo_av1_playback_drain(donor,NULL,NULL),"donor drain");
    NeoAV1Saved *saved=neo_av1_playback_capture(donor);need(saved!=NULL,"capture");
    need(!neo_av1_saved_encode(saved),"encode snapshot");size_t bytes=neo_av1_saved_bytes(saved);need(bytes>0,"held bytes");
    neo_av1_playback_close(&donor);need(donor==NULL,"donor closed before restore");
    uint64_t compared=0,frames=0;unsigned recreated=0;
    NeoAV1Playback *test=neo_av1_playback_open(42);
    /* Reuse the recipient, including interrupted frame work. A fresh recipient
     * on every iteration missed the real player's post-flush readiness failure. */
    for(int repeat=0;repeat<12;repeat++) {
        NeoAV1Playback *oracle=neo_av1_playback_open(777);
        need(test && oracle,"recipients");
        NeoAV1RestoreInfo info={0};
        need(neo_av1_playback_restore_detailed(oracle,saved,&info)<0 && info.reason==NEO_AV1_RESTORE_SESSION && !info.attempts,"different session must refuse before reset");
        if(repeat) {
            for(size_t i=cp+80;i<in.count && i<cp+81+(unsigned)repeat%9;i++)feed(test,&in,i,NULL);
            neo_av1_playback_flush(test);
        }
        need(!neo_av1_playback_restore_detailed(test,saved,&info) && !info.reason,"compatible reused decoder restore");
        recreated+=info.recreated;
        for(size_t i=0;i<cp;i++)feed(oracle,&in,i,NULL);
        need(!neo_av1_playback_drain(oracle,NULL,NULL),"oracle prefix drain");
        size_t end=cp+80<in.count?cp+80:in.count;
        for(size_t begin=cp;begin<end;begin+=16) {
            Images a={0},b={0};size_t stop=begin+16<end?begin+16:end;
            for(size_t i=begin;i<stop;i++) {feed(test,&in,i,&a);feed(oracle,&in,i,&b);}
            need(!neo_av1_playback_drain(test,collect,&a),"restored drain");
            need(!neo_av1_playback_drain(oracle,collect,&b),"normal drain");
            need(a.count==b.count,"suffix frame count");
            for(size_t i=0;i<a.count;i++) {
                Image *x=&a.images[i],*y=&b.images[i];
                need(x->pts==y->pts && x->width==y->width && x->height==y->height && x->depth==y->depth && x->bytes==y->bytes,"suffix geometry/time");
                need(!memcmp(x->pixels,y->pixels,x->bytes),"suffix pixel mismatch");compared+=x->bytes;frames++;
            }
            clear(&a);clear(&b);
        }
        neo_av1_playback_close(&oracle);
    }
    /* The original failure reproduces after the host flush with short in-flight
     * packet runs. Exercise it repeatedly without masking it by a full drain. */
    for(int repeat=0;repeat<32;repeat++) {
        NeoAV1RestoreInfo info={0};neo_av1_playback_flush(test);
        need(!neo_av1_playback_restore_detailed(test,saved,&info),"interrupted-work restore");recreated+=info.recreated;
        for(size_t i=cp;i<cp+1+(unsigned)repeat%23;i++)feed(test,&in,i,NULL);
    }
    need(recreated>0,"cancelled-worker readiness path exercised");
    neo_av1_playback_close(&test);
    neo_av1_saved_free(&saved);need(saved==NULL,"snapshot released");
    for(size_t i=0;i<in.count;i++)free(in.packets[i].data);free(in.packets);
    printf("{\"passed\":true,\"closedDonor\":true,\"wrongSessionRejected\":true,\"restores\":44,\"recreated\":%u,\"frames\":%llu,\"comparedBytes\":%llu,\"heldBytes\":%zu}\n",recreated,(unsigned long long)frames,(unsigned long long)compared,bytes);
    return 0;
}
