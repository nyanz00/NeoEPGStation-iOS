/* BSD-2-Clause. Private PC experiment; not an app or stable file format. */
#ifndef NEO_STORAGE_H
#define NEO_STORAGE_H
#include <stddef.h>
#include <stdint.h>
#include "dav1d/dav1d.h"
#define NEO_STORAGE_METHODS 9
#define NEO_STORAGE_REPEATS 3
typedef struct NeoStorageMetrics {
    size_t held_bytes,pixel_bytes;
    double save_ms[NEO_STORAGE_REPEATS],restore_ms[NEO_STORAGE_REPEATS];
    int detached,verified;
} NeoStorageMetrics;
int neo_storage_measure(Dav1dContext *,int,NeoStorageMetrics *);
const char *neo_storage_method(int);

/* Records full frame-header dependencies, conservatively including all seven
 * declared image references. Not a claim of the minimum block-level subgraph. */
typedef struct NeoTrace NeoTrace;
typedef struct NeoRecipe NeoRecipe;
NeoTrace *neo_trace_start(Dav1dContext *);
void neo_trace_stop(NeoTrace *);
void neo_trace_free(NeoTrace **);
NeoRecipe *neo_recipe_build(NeoTrace *,size_t);
void neo_recipe_free(NeoRecipe **);
void neo_recipe_start(NeoRecipe *,Dav1dContext *);
void neo_recipe_stop(NeoRecipe *);
size_t neo_recipe_count(const NeoRecipe *);
const uint8_t *neo_recipe_packet(const NeoRecipe *,size_t,size_t *,int64_t *);
void neo_recipe_stats(const NeoRecipe *,size_t *,size_t *,size_t *,size_t *);
int neo_recipe_verify_refs(Dav1dContext *,Dav1dContext *);
/* Called only by the instrumented clone's OBU parser. */
int neo_storage_header(Dav1dContext *,const Dav1dData *,int,const uint8_t *,const uint8_t *,const uint8_t *);
int neo_storage_obu(Dav1dContext *,const Dav1dData *,int,const uint8_t *,const uint8_t *);
#endif
