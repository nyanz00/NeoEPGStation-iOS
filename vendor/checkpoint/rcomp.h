/* Diagnostic bridge. No Metal, dav1d or FFmpeg types cross this boundary. */
#ifndef NEO_RCOMP_H
#define NEO_RCOMP_H
#include <stddef.h>
#include <stdint.h>
#include "metal-zstd-input.h"
#define NEO_RCOMP_BLOCK 65536u
#define NEO_RCOMP_SLOT (NEO_RCOMP_BLOCK+NEO_RCOMP_BLOCK/255u+16u)
typedef struct NeoRcompInput { const uint8_t *data; size_t size; uint32_t row_width,word_bytes; const NeoRcompGeometry *geometry; } NeoRcompInput;
typedef struct NeoRcompOutput { uint8_t *data; size_t size; } NeoRcompOutput;
typedef struct NeoRcompMetrics {
    double gpu_ms,wait_ms;
    double stage_ms[8]; /* match, parse, histogram, Huffman, FSE, packing, assembly, preprocessing */
    double host_ms[5]; /* input preparation, raw upload, command encoding/submission, CPU completion block, output copy */
    uint64_t input_bytes,output_bytes;
    int wait_count,batch_count,max_in_flight;
    int stage_timing_available;
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
int neo_lscomp_begin(double *);
void neo_lscomp_end(void);
void neo_lscomp_last_metrics(NeoRcompMetrics *);
int neo_lscomp_cpu_pack(const NeoRcompInput *,NeoRcompOutput *,unsigned);
int neo_lscomp_gpu_pack(const NeoRcompInput *,NeoRcompOutput *,unsigned);
int neo_lscomp_unpack(const uint8_t *,size_t,uint8_t *,size_t);
int neo_mzstd_begin(double *);
void neo_mzstd_end(void);
void neo_mzstd_last_metrics(NeoRcompMetrics *);
/* Native diagnostic control only. Default is the parallel encoder. */
void neo_mzstd_scalar_control(int);
void neo_mzstd_preprocessing_control(int);
int neo_mzstd_cpu_pack(const NeoRcompInput *,NeoRcompOutput *,unsigned);
int neo_mzstd_gpu_pack(const NeoRcompInput *,NeoRcompOutput *,unsigned);
static inline int neo_checkpoint_gpu_method(int m) {return m==10 || m==12 || m==14 || m==15 || m==17;}
static inline int neo_checkpoint_gpu_begin(int m,double *ms) {return m==15 || m==17?neo_mzstd_begin(ms):m==10?neo_rcomp_begin(ms):neo_lscomp_begin(ms);}
static inline void neo_checkpoint_gpu_end(int m) {if(m==15 || m==17)neo_mzstd_end();else if(m==10)neo_rcomp_end();else neo_lscomp_end();}
static inline void neo_checkpoint_gpu_metrics(int m,NeoRcompMetrics *out) {if(m==15 || m==17)neo_mzstd_last_metrics(out);else if(m==10)neo_rcomp_last_metrics(out);else neo_lscomp_last_metrics(out);}
#endif
