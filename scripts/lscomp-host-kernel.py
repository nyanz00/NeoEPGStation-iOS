"""Host correctness adapter for Metal tile analysis/emission, not GPU timing."""
from pathlib import Path
import re
root=Path(__file__).resolve().parents[1]
s=(root/'vendor/checkpoint/lscomp.metal').read_text()
for name in ('neo_ls_scan','neo_ls_bases'):
    a=s.index('kernel void '+name);b=s.index('{',a);depth=1;c=b+1
    while depth:
        if s[c]=='{':depth+=1
        elif s[c]=='}':depth-=1
        c+=1
    s=s[:a]+s[c:]
s=s.replace('#include <metal_stdlib>','').replace('using namespace metal;','')
s=re.sub(r'\[\[(?:buffer\(\d+\)|thread_position_in_grid)\]\]','',s)
out=root/'.local/lscomp-host-kernel.inc';out.parent.mkdir(exist_ok=True);out.write_bytes(s.encode())
