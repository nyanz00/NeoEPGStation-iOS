/* BSD-2-Clause. Independent diagnostic API; no FFmpeg/dav1d types cross it. */
#ifndef NEO_CHECKPOINT_LAB_H
#define NEO_CHECKPOINT_LAB_H
#include <stddef.h>
#include <stdint.h>
#define NEO_CHECKPOINT_REPEATS 5
typedef struct NeoCheckpointPacket {
    const uint8_t *data;
    size_t size;
    double seconds;
} NeoCheckpointPacket;
typedef struct NeoCheckpointResult {
    int status; /* 0=success; 1001=input, 1002=boundary, 1003=mismatch,
                 1004=no target/keyframe, 1005=memory, 1006=cancel, 1007=timeout, 1008=native */
    int decoder_error, failure_stage;
    int threads, frame_contexts, packed;
    uint64_t compared_frames, compared_pixel_bytes;
    uint64_t retained_bytes, state_bytes, picture_bytes;
    uint32_t unique_pictures, width, height, bit_depth;
    double checkpoint_seconds, target_seconds, first_following_key_seconds;
    double save_ms, drain_before_save_ms;
    double repeated_save_ms[NEO_CHECKPOINT_REPEATS];
    double restored_ms[NEO_CHECKPOINT_REPEATS];
    double restore_only_ms[NEO_CHECKPOINT_REPEATS];
    uint64_t sampled_footprint_bytes[NEO_CHECKPOINT_REPEATS];
    uint64_t before_bytes, sampled_peak_bytes, after_bytes;
    int empty_rejected, busy_rejected, wrong_owner_rejected, suffix_without_state_rejected;
    int restore_count, temporary_save_free_count, target_verified_count;
    int full_suffix_passes, allocation_verification_passes, original_pixels_detached;
} NeoCheckpointResult;
/* Synchronous worker-only call. Input remains borrowed until return. One
 * checkpoint at a time; configured worker/frame parallelism; never normal playback. */
int neo_checkpoint_lab_run(const NeoCheckpointPacket *packets, size_t count,
    double gop_seconds, double distance_seconds, int threads, int packed, NeoCheckpointResult *out,
    int (*cancelled)(void *), void *cookie);
uint64_t neo_checkpoint_lab_footprint(void);
#endif
