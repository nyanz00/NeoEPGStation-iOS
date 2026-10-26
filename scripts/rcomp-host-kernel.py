"""Prepare a host integer-kernel correctness test; never a GPU speed estimate."""
from pathlib import Path
import re
root=Path(__file__).resolve().parents[1]
src=(root/'vendor/rcomp-metal/lz4.metal').read_text()
src=src.replace('#include <metal_stdlib>','').replace('using namespace metal;','')
src=re.sub(r'\[\[(?:buffer\(\d+\)|thread_position_in_grid)\]\]','',src)
out=root/'.local/rcomp-host-kernel.inc'
out.parent.mkdir(exist_ok=True)
out.write_bytes(src.encode())
