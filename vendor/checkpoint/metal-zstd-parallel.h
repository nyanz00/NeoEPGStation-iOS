/* BSD-3-Clause. Bounded parallel Zstd work layout. All buffers are reusable;
 * no entropy tables or image-sized arrays live in per-thread private memory. */
#ifndef NEO_METAL_ZSTD_PARALLEL_H
#define NEO_METAL_ZSTD_PARALLEL_H
#define NZ_PART 4096u
#define NZ_PARTS 16u
#define NZ_STREAM_SLOT 24576u
#define NZ_REGIONS 5u
#define NZ_TILES 128u
#ifdef __METAL_VERSION__
#define NZ_G threadgroup
#else
#define NZ_G
#endif
typedef struct NzRecord {NzSeq s;NzU literal;} NzRecord;
typedef struct NzPart {NzU ns,nl,tail,so,lo,carry;} NzPart;
typedef struct NzWork {
    NzPart part[16];
    NzU ns,nl,hvalid,maxbits;
    NzU hist[256],seqhist[3][64];
    NzU sorted[256],count[512],parent[512],length[256],code[256];
    NzFse fse[3];
    NzU mode[3],tableSize[3],state[3];
    NzB tableHeader[3][128],hheader[128];
    NzU hhsize,groupSum[5][128],groupBase[5][128],total[5],bytes[5];
    NzU frame,headerEnd,totalSize,raw,useHuff,litHeader,litBytes;
} NzWork;

static NzU nzp_match_length(NZ_D const NzB *src,NzU at,NzU off,NzU end) {
    /* Keep the established exact comparison. The native GPU oracle rejected
     * the word-at-a-time prototype even after changing its byte selection.
     * Literal copies and FSE remain cooperative; never trade correctness for
     * an unverified match-length shortcut. */
    NzU len=0;while(at+len<end && src[at+len]==src[at+len-off])len++;return len;
}
/* The leader only decides sequences. Payload copying is cooperative after it
 * finishes; records and their literal prefix positions stay in group memory. */
static void nzp_records(NZ_D const NzB *src,NzU n,NZ_D const NzU *matches,
                       NZ_G NzRecord *records,NZ_D NzPart *part,NzU begin) {
    NzU end=begin+NZ_PART;if(end>n)end=n;NzU at=begin,anchor=begin,ns=0,nl=0;
    while(at+4<=end) {
        NzU off=matches[at];if(!off || off>at || off>65535) {at++;continue;}
        NzU len=nzp_match_length(src,at,off,end);if(len<4) {at++;continue;}
        NzU ll=at-anchor;nl+=ll;
        records[ns++]=(NzRecord){{ll,len-3,off+3},(nl<<16)|anchor};at+=len;anchor=at;
    }
    NzU tail=end>anchor?end-anchor:0;part->ns=ns;part->nl=nl+tail;part->tail=tail;
}
static NzU nzp_literal_source(NZ_G const NzRecord *records,NzU ns,NzU tailStart,NzU nl,NzU tail,NzU ordinal) {
    NzU low=0,high=ns;
    while(low<high) {NzU mid=(low+high)/2;if((records[mid].literal>>16)<=ordinal)low=mid+1;else high=mid;}
    if(low==ns)return tailStart+ordinal-(nl-tail);
    NzRecord r=records[low];return (r.literal&65535)+ordinal-((r.literal>>16)-r.s.ll);
}

static void nzp_parse(NZ_D const NzB *src,NzU n,NZ_D const NzU *matches,
                     NZ_D NzSeq *seq,NZ_D NzB *lit,NZ_D NzPart *part,NzU begin) {
    NzU end=begin+NZ_PART;if(end>n)end=n;
    NzU at=begin,anchor=begin,ns=0,nl=0;
    while(at+4<=end) {
        NzU off=matches[at];if(!off || off>at || off>65535) {at++;continue;}
        NzU len=0;while(at+len<end && src[at+len]==src[at+len-off])len++;
        if(len<4) {at++;continue;}
        for(NzU j=anchor;j<at;j++)lit[nl++]=src[j];
        seq[ns++]=(NzSeq){at-anchor,len-3,off+3};at+=len;anchor=at;
    }
    for(NzU j=anchor;j<end;j++)lit[nl++]=src[j];
    part->ns=ns;part->nl=nl;part->tail=end>anchor?end-anchor:0;
}
static void nzp_compact_offsets(NZ_D NzWork *w) {
    NzU ns=0,nl=0,carry=0;
    for(NzU j=0;j<16;j++) {
        NZ_D NzPart *p=w->part+j;p->so=ns;p->lo=nl;p->carry=carry;
        ns+=p->ns;nl+=p->nl;carry=p->ns?p->tail:carry+p->tail;
    }w->ns=ns;w->nl=nl;
}
static NzU nzp_code(NzSeq s,NzU family) {return family==0?nz_llcode(s.ll):family==1?nz_mlcode(s.ml):nz_log(s.off);}
static NzU nzp_init(NZ_D const NzFse *f,NzU symbol) {
    if(!f->log)return 0;NzU n=(f->bits[symbol]+32768)>>16,v=(n<<16)-f->bits[symbol];
    return f->state[(int)(v>>n)+f->find[symbol]];
}
/* Each FSE family is an independent reverse state chain. Tokens are packed
 * later by thousands of lanes instead of serial byte-at-a-time writes. */
static void nzp_chain(NZ_D NzWork *w,NZ_D const NzSeq *seq,NZ_D NzU *tokens,NzU f) {
    NzU n=w->ns;if(!n)return;NZ_D const NzFse *t=w->fse+f;
    NzU state=nzp_init(t,nzp_code(seq[n-1],f));tokens[(n-1)*4+f]=0;
    for(NzU j=n-1;j>0;) {
        NzU c=nzp_code(seq[--j],f),bits=t->log?(state+t->bits[c])>>16:0;
        tokens[j*4+f]=(bits<<16)|(state&((1u<<bits)-1));
        if(t->log)state=t->state[(int)(state>>bits)+t->find[c]];
    }w->state[f]=state;
}
static NzU nzp_seqbits(NzSeq s,NZ_D const NzU *t) {
    return (t[0]>>16)+(t[1]>>16)+(t[2]>>16)+nz_llbits[nz_llcode(s.ll)]+nz_mlbits[nz_mlcode(s.ml)]+nz_log(s.off);
}
/* Sorted leaves and the monotonic internal-node queue give a linear tree
 * construction, replacing repeated heap operations and their private arrays. */
static void nzp_tree(NZ_D NzWork *w) {
    NzU a=0,b=256,next=256;
    while(next<511) {
        NzU x=(a<256 && (b==next || w->count[w->sorted[a]]<=w->count[b]))?w->sorted[a++]:b++;
        NzU y=(a<256 && (b==next || w->count[w->sorted[a]]<=w->count[b]))?w->sorted[a++]:b++;
        w->count[next]=w->count[x]+w->count[y];w->parent[x]=w->parent[y]=next++;
    }
}
static void nzp_canonical(NZ_D NzWork *w) {
    NzU rank[16]={0},base[16],minimum=0,maxbits=0;
    for(NzU j=0;j<256;j++) {rank[w->length[j]]++;if(w->length[j]>maxbits)maxbits=w->length[j];}
    w->maxbits=maxbits;if(maxbits>11) {w->hvalid=0;return;}
    for(NzU k=maxbits;k>0;k--) {base[k]=minimum;minimum=(minimum+rank[k])>>1;}
    for(NzU j=0;j<256;j++)w->code[j]=base[w->length[j]]++;
    NzU weights[256];for(NzU j=0;j<256;j++)weights[j]=maxbits+1-w->length[j];
    NzU h=nz_weights(w->hheader+1,weights,255);w->hvalid=h && h<128;
    w->hheader[0]=(NzB)h;w->hhsize=h+1;
}
/* Only small headers are serial; all payload copies use the full group. */
static void nzp_layout(NZ_D NzWork *w,NzU n,NZ_D NzB *out) {
    nz_le(out,0xfd2fb528,4);NzU frame=n<256?6:7;w->frame=frame;
    out[4]=n<256?0x20:0x60;if(n<256)out[5]=(NzB)n;else nz_le(out+5,n-256,2);
    NzU nl=w->nl,lh=nl<32?1:nl<4096?2:3,h=w->hhsize+6;
    for(NzU j=1;j<5;j++)h+=w->bytes[j];
    w->useHuff=w->hvalid && h+5<nl+lh;NzU p=frame+3;
    if(w->useHuff) {
        NzU header=nl<1024 && h<1024?3:nl<16384 && h<16384?4:5;
        Nz64 v=2u|((Nz64)(header==3?1:header==4?2:3)<<2)|((Nz64)nl<<4)|((Nz64)h<<(header==3?14:header==4?18:22));
        for(NzU j=0;j<header;j++)out[p++]=(NzB)(v>>(j*8));
        w->litHeader=p;w->litBytes=h;
        for(NzU j=0;j<w->hhsize;j++)out[p+j]=w->hheader[j];
        for(NzU j=0;j<3;j++)nz_le(out+p+w->hhsize+j*2,w->bytes[j+1],2);
    }else {
        NzU v=lh==1?nl<<3:((lh==2?1u:3u)<<2)|(nl<<4);nz_le(out+p,v,lh);p+=lh;w->litHeader=p;w->litBytes=nl;
    }
    p+=w->litBytes;NzU ns=w->ns;
    if(ns<128)out[p++]=(NzB)ns;else {out[p++]=(NzB)(128+(ns>>8));out[p++]=(NzB)ns;}
    if(ns) {
        out[p++]=(NzB)((w->mode[0]<<6)|(w->mode[2]<<4)|(w->mode[1]<<2));
        for(NzU k=0;k<3;k++) {NzU f=k==1?2:k==2?1:0;for(NzU j=0;j<w->tableSize[f];j++)out[p++]=w->tableHeader[f][j];}
    }
    w->headerEnd=p;w->totalSize=p+(ns?w->bytes[0]:0);w->raw=w->totalSize-frame-3>=n;
    if(w->raw)w->totalSize=frame+3+n;
    nz_le(out+frame,(w->raw?1u:5u)|((w->totalSize-frame-3)<<3),3);
}
#endif
