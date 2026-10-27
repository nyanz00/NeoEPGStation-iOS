/* BSD-2-Clause. Decode API is exclusively owned by its caller. Captured immutable
 * buffers may be compressed on one background worker; compressed states are
 * transferable only within the same player session and identical decoder setup. */
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include "dav1d/dav1d.h"
#include "lossless.h"
#include "NeoCheckpointPlayback.h"
struct NeoAV1Playback { Dav1dContext *decoder; uint64_t session; };
struct NeoAV1Saved { NeoLosslessCheckpoint *state; uint64_t session; int encoded; };
NeoAV1Playback *neo_av1_playback_open(uint64_t session) {
    if(!session)return NULL;
    NeoAV1Playback *p=calloc(1,sizeof(*p));if(!p)return NULL;
    Dav1dSettings settings;dav1d_default_settings(&settings);
    settings.n_threads=6;settings.max_frame_delay=3;
    settings.logger.callback=NULL;
    if(dav1d_open(&p->decoder,&settings)<0) {free(p);return NULL;}
    p->session=session;return p;
}
static int take(NeoAV1Playback *p,NeoAV1Output output,void *cookie) {
    Dav1dPicture picture={0};int e=dav1d_get_picture(p->decoder,&picture);if(e)return e;
    if(picture.p.w>1920 || picture.p.h>1080 || picture.p.bpc>10 || picture.p.layout!=DAV1D_PIXEL_LAYOUT_I420) {
        dav1d_picture_unref(&picture);return DAV1D_ERR(ENOTSUP);
    }
    if(output) {
        NeoAV1Frame frame={0};
        for(int i=0;i<3;i++)frame.plane[i]=picture.data[i];
        memcpy(frame.stride,picture.stride,sizeof(frame.stride));
        frame.width=picture.p.w;frame.height=picture.p.h;frame.depth=picture.p.bpc;frame.layout=picture.p.layout;
        frame.timestamp=picture.m.timestamp;frame.duration=picture.m.duration;
        if(picture.seq_hdr) {frame.primaries=picture.seq_hdr->pri;frame.transfer=picture.seq_hdr->trc;
            frame.matrix=picture.seq_hdr->mtrx;frame.full_range=picture.seq_hdr->color_range;}
        output(cookie,&frame);
    }
    dav1d_picture_unref(&picture);return 0;
}
int neo_av1_playback_feed(NeoAV1Playback *p,const uint8_t *bytes,size_t count,
                          int64_t pts,int64_t duration,int64_t position,NeoAV1Output output,void *cookie) {
    if(!p || !bytes || !count || count>16*1024*1024)return DAV1D_ERR(EINVAL);
    Dav1dData data={0};uint8_t *owned=dav1d_data_create(&data,count);if(!owned)return DAV1D_ERR(ENOMEM);
    memcpy(owned,bytes,count);data.m.timestamp=pts;data.m.duration=duration;data.m.offset=position;
    int e=0;unsigned attempts=0;
    while(data.sz && ++attempts<1024) {
        e=dav1d_send_data(p->decoder,&data);
        if(e && e!=DAV1D_ERR(EAGAIN))break;
        int r=take(p,output,cookie);
        if(r && r!=DAV1D_ERR(EAGAIN)) {e=r;break;}
    }
    if(data.sz && (!e || e==DAV1D_ERR(EAGAIN)))e=DAV1D_ERR(EINVAL);
    dav1d_data_unref(&data);return e==DAV1D_ERR(EAGAIN)?0:e;
}
int neo_av1_playback_drain(NeoAV1Playback *p,NeoAV1Output output,void *cookie) {
    if(!p)return DAV1D_ERR(EINVAL);
    for(;;) {int e=take(p,output,cookie);if(e==DAV1D_ERR(EAGAIN))return 0;if(e)return e;}
}
void neo_av1_playback_flush(NeoAV1Playback *p) {if(p)dav1d_flush(p->decoder);}
void neo_av1_playback_close(NeoAV1Playback **ptr) {
    if(!ptr || !*ptr)return;NeoAV1Playback *p=*ptr;*ptr=NULL;dav1d_close(&p->decoder);free(p);
}
NeoAV1Saved *neo_av1_playback_capture(NeoAV1Playback *p) {
    if(!p)return NULL;NeoAV1Saved *s=calloc(1,sizeof(*s));if(!s)return NULL;
    s->session=p->session;
    if(neo_lossless_capture(p->decoder,7,&s->state)) {free(s);return NULL;}
    return s;
}
int neo_av1_saved_encode(NeoAV1Saved *s) {
    if(!s || s->encoded)return DAV1D_ERR(EINVAL);
    int e=neo_lossless_encode(s->state);if(!e)s->encoded=1;return e;
}
size_t neo_av1_saved_bytes(const NeoAV1Saved *s) {
    if(!s)return 0;NeoLosslessStats stats={0};neo_lossless_stats(s->state,&stats);return stats.held_bytes+sizeof(*s);
}
int neo_av1_playback_restore(NeoAV1Playback *p,const NeoAV1Saved *s) {
    if(!p || !s || !s->encoded || p->session!=s->session)return DAV1D_ERR(EINVAL);
    return neo_lossless_restore_compatible(p->decoder,s->state);
}
void neo_av1_saved_free(NeoAV1Saved **ptr) {
    if(!ptr || !*ptr)return;NeoAV1Saved *s=*ptr;*ptr=NULL;neo_lossless_free(&s->state);free(s);
}
