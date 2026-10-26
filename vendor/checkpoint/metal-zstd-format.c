/* BSD-3-Clause. CPU reference/control, not a fallback for Metal errors. */
#include "rcomp.h"
#include "metal-zstd-core.h"
#include <stdlib.h>
#include <string.h>
int neo_mzstd_cpu_pack(const NeoRcompInput *in,NeoRcompOutput *out,unsigned count) {
    if(!in || !out || !count || count>8)return 1001;
    NzU *head=malloc(NZ_HASH*4),*prev=malloc(NZ_BLOCK*4),*matches=malloc(NZ_BLOCK*4);
    NzSeq *seq=malloc(16384*sizeof(*seq));NzB *lit=malloc(NZ_BLOCK),*huf=malloc(NZ_BLOCK*2),*encoded=malloc(NZ_SLOT);int error=0;
    if(!head || !prev || !matches || !seq || !lit || !huf || !encoded) {error=1005;goto done;}
    size_t total=0;for(unsigned j=0;j<count;j++) {if(!in[j].data || !in[j].size || in[j].size>48*1024*1024) {error=1001;goto done;}total+=in[j].size;}if(total>48*1024*1024) {error=1005;goto done;}
    for(unsigned j=0;j<count;j++) {
        size_t blocks=(in[j].size+NZ_BLOCK-1)/NZ_BLOCK;out[j].data=malloc(in[j].size+blocks*1024);out[j].size=0;if(!out[j].data) {error=1005;goto done;}
        for(size_t begin=0;begin<in[j].size;begin+=NZ_BLOCK) {
            const NzB *src=in[j].data+begin;NzU n=(NzU)(in[j].size-begin);if(n>NZ_BLOCK)n=NZ_BLOCK;
            memset(head,255,NZ_HASH*4);memset(prev,255,NZ_BLOCK*4);memset(matches,0,NZ_BLOCK*4);
            for(NzU p=0;p+4<=n;p++) {
                if(p && (p&31) && src[p]==src[p-1] && src[p+1]==src[p] && src[p+2]==src[p] && src[p+3]==src[p])continue;
                NzU hash=nz_hash(src+p);prev[p]=head[hash];head[hash]=p;
            }
            for(NzU p=0;p+4<=n;p++) {
                NzU best=~0u,c=prev[p],tries=0;
                for(NzU off=1;off<=32 && off<=p;off*=2)if(!memcmp(src+p,src+p-off,4)) {best=off;break;}
                while(best!=1 && c!=~0u && tries++<32) {if(c<p && p-c<best && !memcmp(src+p,src+c,4))best=p-c;c=prev[c];}
                if(best!=~0u)matches[p]=best;
            }
            NzU size=nz_block(src,n,matches,seq,lit,huf,encoded);if(!size || size>NZ_SLOT) {error=1010;goto done;}
            memcpy(out[j].data+out[j].size,encoded,size);out[j].size+=size;
        }
        void *smaller=realloc(out[j].data,out[j].size);if(smaller)out[j].data=smaller;
    }
done:free(head);free(prev);free(matches);free(seq);free(lit);free(huf);free(encoded);return error;
}
#ifndef __APPLE__
int neo_mzstd_begin(double *ms) {if(ms)*ms=0;return 1009;}
void neo_mzstd_end(void) {}
void neo_mzstd_last_metrics(NeoRcompMetrics *out) {memset(out,0,sizeof(*out));}
int neo_mzstd_gpu_pack(const NeoRcompInput *in,NeoRcompOutput *out,unsigned count) {(void)in;(void)out;(void)count;return 1009;}
#endif
