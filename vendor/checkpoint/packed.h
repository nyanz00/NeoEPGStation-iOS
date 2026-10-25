/* BSD-2-Clause. Lossless packing for the isolated checkpoint diagnostic. */
#ifndef NEO_PACKED_CHECKPOINT_H
#define NEO_PACKED_CHECKPOINT_H
#include "neo_checkpoint.h"
typedef struct NeoPackedCheckpoint NeoPackedCheckpoint;
typedef struct NeoPackedStats {
    size_t state_bytes, pixel_bytes, metadata_bytes, total_bytes;
    unsigned unique_pictures;
    int pixel_references_detached;
} NeoPackedStats;
int neo_packed_save(Dav1dContext *c, NeoPackedCheckpoint **out);
int neo_packed_restore(Dav1dContext *c, const NeoPackedCheckpoint *saved);
void neo_packed_free(NeoPackedCheckpoint **saved);
void neo_packed_stats(const NeoPackedCheckpoint *saved, NeoPackedStats *out);
/* Untimed check: all image allocation bytes, including padding and tail. */
int neo_packed_verify_buffers(Dav1dContext *c, const NeoPackedCheckpoint *saved);
int neo_packed_codec_selftest(void);
#endif
