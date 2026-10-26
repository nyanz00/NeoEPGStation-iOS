/* Diagnostic bridge. No Metal, dav1d or FFmpeg types cross this boundary. */
#ifndef NEO_RCOMP_H
#define NEO_RCOMP_H
#include <stddef.h>
#include <stdint.h>
#define NEO_RCOMP_BLOCK 65536u
#define NEO_RCOMP_SLOT (NEO_RCOMP_BLOCK+NEO_RCOMP_BLOCK/255u+16u)
typedef struct NeoRcompInput { const uint8_t *data; size_t size; } NeoRcompInput;
typedef struct NeoRcompOutput { uint8_t *data; size_t size; } NeoRcompOutput;
typedef struct NeoRcompMetrics {
    double gpu_ms,wait_ms;
    uint64_t staging_bytes;
    int dispatches;
} NeoRcompMetrics;
/* Sessions belong to the calling diagnostic thread. No CPU fallback on GPU error. */
int neo_rcomp_begin(double *setup_ms);
void neo_rcomp_end(void);
void neo_rcomp_last_metrics(NeoRcompMetrics *out);
int neo_rcomp_gpu_pack(const NeoRcompInput *,NeoRcompOutput *,unsigned);
int neo_rcomp_cpu_pack(const NeoRcompInput *,NeoRcompOutput *,unsigned);
int neo_rcomp_assemble(const uint8_t *padded,size_t raw_size,const uint8_t *slots,
                      const uint32_t *sizes,NeoRcompOutput *out);
int neo_rcomp_unpack(const uint8_t *,size_t,uint8_t *,size_t);
#endif
