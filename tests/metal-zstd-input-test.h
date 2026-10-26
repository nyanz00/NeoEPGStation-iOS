/* Independent, deliberately scalar in-place oracle matching the existing
 * checkpoint delta/shuffle contract, including row and allocation padding. */
static void input_reference(uint8_t *data,const NeoRcompGeometry *g) {
    for(unsigned p=0;p<g->planes;p++)for(unsigned y=0;y<g->height[p];y++) {
        uint8_t *row=data+g->offset[p]+y*g->stride[p];unsigned w=g->width[p];int previous=0;
        if(g->word_bytes==1)for(unsigned x=0;x<w;x++) {int cur=row[x],d=(int8_t)(cur-previous);previous=cur;row[x]=(uint8_t)(d>=0?2*d:-2*d-1);}
        else {
            uint16_t temporary[1920];for(unsigned x=0;x<w;x++) {int cur=row[x*2]|(unsigned)row[x*2+1]<<8,d=cur-previous;previous=cur;temporary[x]=(uint16_t)(d>=0?2*d:-2*d-1);}
            for(unsigned x=0;x<w;x++) {row[x]=(uint8_t)temporary[x];row[w+x]=(uint8_t)(temporary[x]>>8);}
        }
    }
}
static size_t input_fixture(NeoRcompGeometry *g,unsigned width,unsigned height,unsigned word) {
    memset(g,0,sizeof(*g));g->planes=3;g->word_bytes=word;size_t size=64;
    for(unsigned p=0;p<3;p++) {g->width[p]=p?(width+1)/2:width;g->height[p]=p?(height+1)/2:height;
        g->stride[p]=(g->width[p]*word+63)&~63u;g->offset[p]=(unsigned)size;size+=g->stride[p]*g->height[p]+128;}
    return size+73;
}
static int input_cpu_test(void) {
    const unsigned widths[]={1,7,31,1440,1920};
    for(unsigned word=1;word<=2;word++)for(unsigned k=0;k<5;k++) {
        NeoRcompGeometry g;size_t n=input_fixture(&g,widths[k],k<3?9:1080,word);
        uint8_t *raw=malloc(n),*ref=malloc(n),*out=malloc(n);if(!raw || !ref || !out)return 2;
        unsigned rng=0x7ead1234;for(size_t j=0;j<n;j++) {rng=rng*1664525u+1013904223u;raw[j]=(uint8_t)(rng>>24);}
        memcpy(ref,raw,n);input_reference(ref,&g);if(!nzi_valid(&g,n))return 3;
        nzi_prepare(raw,&g,0,n,out);if(memcmp(ref,out,n))return 4;
        for(size_t pos=0;pos<n;) {size_t take=(pos%3==0?65536:pos%3==1?1031:7);if(take>n-pos)take=n-pos;nzi_prepare(raw,&g,pos,take,out+pos);pos+=take;}
        if(memcmp(ref,out,n))return 5;free(raw);free(ref);free(out);
    }return 0;
}
