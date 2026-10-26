/* Lossless-only adaptation of lsCOMP. See vendor/lscomp/LICENSE. */
#ifndef NEO_LSCOMP_H
#define NEO_LSCOMP_H
#include "rcomp.h"
typedef struct NeoLsImage {
    uint32_t raw_bytes,row_width,word_bytes,first_byte,first_tile,tile_columns,tile_rows,tiles;
} NeoLsImage;
typedef struct NeoLsConfig {NeoLsImage image[8];uint32_t images,tiles,groups;} NeoLsConfig;
int neo_lscomp_geometry(const NeoRcompInput *,NeoLsImage *);
int neo_lscomp_assemble(const NeoLsImage *,const uint8_t *,const uint8_t *,size_t,NeoRcompOutput *);
#endif
