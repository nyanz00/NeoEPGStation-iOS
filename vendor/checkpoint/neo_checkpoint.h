/* Experimental in-process checkpoint API for pinned dav1d 1.5.4 only. */
#ifndef NEO_CHECKPOINT_H
#define NEO_CHECKPOINT_H
#include <stddef.h>
#include "dav1d/dav1d.h"
typedef struct NeoCheckpoint NeoCheckpoint;
typedef struct NeoCheckpointStats {
    size_t state_bytes;
    size_t retained_bytes;
    size_t picture_bytes;
    unsigned unique_pictures;
    unsigned unique_allocations;
} NeoCheckpointStats;
/* Caller must drain all frames and own the decoder API exclusively. Supports
 * multiple workers/frames, default allocator, no pending HDR metadata. Keep the owning
 * decoder alive. This does NOT serialize pointers or copy a decoder/threads. */
int neo_checkpoint_save(Dav1dContext *c, NeoCheckpoint **out);
int neo_checkpoint_restore(Dav1dContext *c, const NeoCheckpoint *saved);
void neo_checkpoint_free(NeoCheckpoint **saved);
void neo_checkpoint_stats(const NeoCheckpoint *saved, NeoCheckpointStats *out);
#endif
