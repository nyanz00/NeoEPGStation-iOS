/* BSD-2-Clause. Experimental AV1 playback; no FFmpeg ABI crosses this boundary. */
#ifndef NEO_CHECKPOINT_PLAYBACK_H
#define NEO_CHECKPOINT_PLAYBACK_H
#include <stddef.h>
#include <stdint.h>
typedef struct NeoAV1Playback NeoAV1Playback;
typedef struct NeoAV1Saved NeoAV1Saved;
typedef struct NeoAV1Frame {
    const uint8_t *plane[3];
    ptrdiff_t stride[2];
    int width,height,depth,layout,primaries,transfer,matrix,full_range;
    int64_t timestamp,duration;
} NeoAV1Frame;
/* Callback planes are borrowed until callback return, never retained. */
typedef void (*NeoAV1Output)(void *, const NeoAV1Frame *);
NeoAV1Playback *neo_av1_playback_open(uint64_t session);
int neo_av1_playback_feed(NeoAV1Playback *, const uint8_t *, size_t,
                          int64_t pts,int64_t duration,int64_t position,NeoAV1Output,void *);
int neo_av1_playback_drain(NeoAV1Playback *,NeoAV1Output,void *);
void neo_av1_playback_flush(NeoAV1Playback *);
void neo_av1_playback_close(NeoAV1Playback **);
NeoAV1Saved *neo_av1_playback_capture(NeoAV1Playback *);
int neo_av1_saved_encode(NeoAV1Saved *);
size_t neo_av1_saved_bytes(const NeoAV1Saved *);
int neo_av1_playback_restore(NeoAV1Playback *,const NeoAV1Saved *);
void neo_av1_saved_free(NeoAV1Saved **);
#endif
