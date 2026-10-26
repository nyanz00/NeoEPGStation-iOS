/* Sequential scheduling oracle for the parallel buffer layout, bit offsets,
 * split-parse joins, FSE tokens and frame assembly. Not a performance result. */
#include "metal-zstd-parallel.h"
static NzU parallel_block(const NzB *src,NzU n,const NzU *matches,NzB *out,bool fast=false) {
    NzWork w={};std::vector<NzSeq> partial(16384),seq(16384);
    std::vector<NzB> partialLit(NZ_BLOCK),lit(NZ_BLOCK),hb(NZ_BLOCK*2),sb(NZ_HASH*4);
    std::vector<NzU> tokens(NZ_BLOCK),offsets(NZ_BLOCK);
    for(NzU p=0;p<16;p++) {
        if(!fast)nzp_parse(src,n,matches,partial.data()+p*1024,partialLit.data()+p*4096,w.part+p,p*4096);
        else {std::vector<NzRecord> records(1024);nzp_records(src,n,matches,records.data(),w.part+p,p*4096);NzPart a=w.part[p];NzU end=std::min(n,(p+1)*4096);
            for(NzU j=0;j<a.ns;j++)partial[p*1024+j]=records[j].s;
            for(NzU j=0;j<a.nl;j++)partialLit[p*4096+j]=src[nzp_literal_source(records.data(),a.ns,end-a.tail,a.nl,a.tail,j)];}
    }
    nzp_compact_offsets(&w);
    for(NzU p=0;p<16;p++) {NzPart a=w.part[p];
        for(NzU j=0;j<a.ns;j++) {NzSeq s=partial[p*1024+j];if(!j)s.ll+=a.carry;seq[a.so+j]=s;}
        memcpy(lit.data()+a.lo,partialLit.data()+p*4096,a.nl);
    }
    for(NzU j=0;j<w.nl;j++)w.hist[lit[j]]++;
    for(NzU j=0;j<w.ns;j++)for(NzU f=0;f<3;f++)w.seqhist[f][nzp_code(seq[j],f)]++;
    if(w.nl>=64) {
        for(NzU floor=1;floor<=256;floor*=2) {
            for(NzU j=0;j<256;j++) {w.count[j]=std::max(w.hist[j],floor);w.sorted[j]=j;}
            std::sort(w.sorted,w.sorted+256,[&](NzU a,NzU b){return w.count[a]<w.count[b] || (w.count[a]==w.count[b] && a<b);});
            nzp_tree(&w);NzU maximum=0;
            for(NzU j=0;j<256;j++) {NzU at=j,bits=0;while(at!=510) {bits++;at=w.parent[at];}w.length[j]=bits;maximum=std::max(maximum,bits);}
            if(maximum<=11)break;
        }nzp_canonical(&w);
    }
    for(NzU f=0;w.ns && f<3;f++) {w.tableSize[f]=nz_seqtable(w.tableHeader[f],w.fse+f,w.seqhist[f],w.ns,w.mode+f);nzp_chain(&w,seq.data(),tokens.data(),f);}
    for(NzU r=0;r<5;r++) {
        NzU quarter=(w.nl+3)/4,begin=r?(r-1)*quarter:0,end=r?std::min(begin+quarter,w.nl):w.ns;
        NzU sum=0,local=0,ordinal=0;
        for(NzU j=end;j>begin;) {j--;NzU tile=ordinal/128;
            if(!(ordinal%128)) {w.groupBase[r][tile]=sum;local=0;}
            if(r)offsets[j]=local;else tokens[j*4+3]=local;
            NzU bits=r?(w.hvalid?w.length[lit[j]]:0):nzp_seqbits(seq[j],tokens.data()+j*4);
            sum+=bits;local+=bits;ordinal++;
        }
        w.total[r]=sum;NzU tail=r || !w.ns?1:w.fse[0].log+w.fse[1].log+w.fse[2].log+1;w.bytes[r]=(sum+tail+7)/8;
    }
    auto write=[](NzB *dst,NzU at,NzU v,NzU bits) {for(NzU k=0;k<bits;k++)if((v>>k)&1)dst[(at+k)/8]|=1u<<((at+k)%8);};
    for(NzU j=0;j<w.ns;j++) {
        NzU *token=tokens.data()+j*4,at=token[3]+w.groupBase[0][(w.ns-1-j)/128];
        for(NzU k=0;k<3;k++) {NzU v=token[2-k];write(sb.data(),at,v,v>>16);at+=v>>16;}
        NzSeq s=seq[j];NzU l=nz_llbits[nz_llcode(s.ll)],m=nz_mlbits[nz_mlcode(s.ml)],o=nz_log(s.off);
        write(sb.data(),at,s.ll,l);at+=l;write(sb.data(),at,s.ml,m);at+=m;write(sb.data(),at,s.off,o);
    }
    if(w.ns) {NzU at=w.total[0];for(NzU k=0;k<3;k++) {NzU f=k==0?1:k==1?2:0;write(sb.data(),at,w.state[f],w.fse[f].log);at+=w.fse[f].log;}write(sb.data(),at,1,1);}
    if(w.hvalid) {
        NzU q=(w.nl+3)/4;
        for(NzU j=0;j<w.nl;j++) {NzU r=j/q,end=std::min((r+1)*q,w.nl),at=offsets[j]+w.groupBase[r+1][(end-1-j)/128];write(hb.data()+r*NZ_STREAM_SLOT,at,w.code[lit[j]],w.length[lit[j]]);}
        for(NzU r=0;r<4;r++)write(hb.data()+r*NZ_STREAM_SLOT,w.total[r+1],1,1);
    }
    nzp_layout(&w,n,out);
    if(w.raw)memcpy(out+w.frame+3,src,n);
    else {
        if(w.useHuff) {NzU pos=w.litHeader+w.hhsize+6;for(NzU r=0;r<4;r++) {memcpy(out+pos,hb.data()+r*NZ_STREAM_SLOT,w.bytes[r+1]);pos+=w.bytes[r+1];}}
        else memcpy(out+w.litHeader,lit.data(),w.nl);
        if(w.ns)memcpy(out+w.headerEnd,sb.data(),w.bytes[0]);
    }return w.totalSize;
}
