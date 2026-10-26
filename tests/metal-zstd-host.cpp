/* Host execution of the shipping encoder arithmetic; not a GPU timing test. */
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <algorithm>
#include "metal-zstd-core.h"
#include "neo_compression_namespace.h"
#include "zstd.h"
static void matching(const NzB *in,NzU n,std::vector<NzU>& matches) {
    std::vector<NzU> head(NZ_HASH,~0u),previous(n,~0u);matches.assign(n,0);
    for(NzU p=0;p+4<=n;p++) {if(p && (p&31) && in[p]==in[p-1] && in[p+1]==in[p] && in[p+2]==in[p] && in[p+3]==in[p])continue;NzU h=nz_hash(in+p);previous[p]=head[h];head[h]=p;}
    for(NzU p=0;p+4<=n;p++) {
        NzU best=~0u,c=previous[p],limit=0;
        for(NzU off=1;off<=32 && off<=p;off*=2)if(!memcmp(in+p,in+p-off,4)) {best=off;break;}
        while(best!=1 && c!=~0u && limit++<32) {if(c<p && p-c<best && !memcmp(in+p,in+c,4))best=p-c;c=previous[c];}
        if(best!=~0u)matches[p]=best;
    }
}
static unsigned cases=0,compressed=0;static uint64_t rawbytes=0,packedbytes=0;
static void check(const NzB *data,NzU n) {
    std::vector<NzU> matches;matching(data,n,matches);std::vector<NzSeq> seq(16384);
    std::vector<NzB> literals(NZ_BLOCK),huff(NZ_BLOCK*2),out(NZ_SLOT+64,0xa5),restored(n+1);
    NzU size=nz_block(data,n,matches.data(),seq.data(),literals.data(),huff.data(),out.data());
    size_t got=ZSTD_decompress(restored.data(),n,out.data(),size);
    if(!size || size>NZ_SLOT || ZSTD_isError(got) || got!=n || memcmp(data,restored.data(),n)) {
        fprintf(stderr,"case=%u raw=%u encoded=%u decoded=%zu error=%s\n",cases,n,size,got,ZSTD_getErrorName(got));
        FILE *f=fopen(".local/mzstd-failed.bin","wb");fwrite(out.data(),1,size,f);fclose(f);
        f=fopen(".local/mzstd-failed-input.bin","wb");fwrite(data,1,n,f);fclose(f);exit(1);
    }
    for(size_t j=NZ_SLOT;j<out.size();j++)if(out[j]!=0xa5)exit(2);
    if(size<n)compressed++;cases++;rawbytes+=n;packedbytes+=size;
}
int main(int argc,char **argv) {
    NzU state=1;for(NzU n:{1u,7u,31u,64u,127u,255u,256u,4095u,16383u,65535u,65536u})for(NzU kind=0;kind<7;kind++) {
        std::vector<NzB> data(n);
        for(NzU j=0;j<n;j++) {state=state*1664525u+1013904223u;
            data[j]=kind==0?0:kind==1?255:kind==2?(NzB)(j%37):kind==3?(NzB)(state>>24):kind==4?(NzB)((state>>28)&7):kind==5?(NzB)(j%256):(j%11?0:(NzB)(state>>24));}
        check(data.data(),n);
    }
    for(int arg=1;arg<argc;arg++) {FILE *f=fopen(argv[arg],"rb");if(!f)return 3;std::vector<NzB> bytes(NZ_BLOCK);size_t n;
        while((n=fread(bytes.data(),1,bytes.size(),f)))check(bytes.data(),(NzU)n);fclose(f);}
    printf("{\"cases\":%u,\"compressedBlocks\":%u,\"rawBytes\":%llu,\"packedBytes\":%llu,\"byteExact\":true,\"gpuMeasured\":false}\n",cases,compressed,(unsigned long long)rawbytes,(unsigned long long)packedbytes);
}
