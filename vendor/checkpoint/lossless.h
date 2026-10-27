/* BSD-2-Clause. Private same-owner diagnostic checkpoints. */
#ifndef NEO_LOSSLESS_H
#define NEO_LOSSLESS_H
#include "dav1d/dav1d.h"
typedef struct NeoLosslessCheckpoint NeoLosslessCheckpoint;
typedef struct NeoLosslessStats {size_t held_bytes,pixel_bytes;int detached;} NeoLosslessStats;
/* Capture runs exclusively on a drained decoder. Encode may then run on a
 * separate worker: it reads only retained, immutable snapshot buffers. */
int neo_lossless_capture(Dav1dContext *,int,NeoLosslessCheckpoint **);
int neo_lossless_encode(NeoLosslessCheckpoint *);
int neo_lossless_restore(Dav1dContext *,const NeoLosslessCheckpoint *);
int neo_lossless_restore_compatible(Dav1dContext *,const NeoLosslessCheckpoint *);
unsigned neo_lossless_readiness(Dav1dContext *);
/* Stages: 1 snapshot, 2 readiness, 3 decoder setup, 4 allocation, 5 geometry,
 * 6 decompression. The legacy diagnostic entry points retain their guards. */
int neo_lossless_restore_compatible_detailed(Dav1dContext *,const NeoLosslessCheckpoint *,int *,unsigned *);
void neo_lossless_free(NeoLosslessCheckpoint **);
void neo_lossless_stats(const NeoLosslessCheckpoint *,NeoLosslessStats *);
const char *neo_lossless_name(int);
#endif
