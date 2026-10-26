"""Prepare only the pinned compression sources and shipping Metal test.

No pods, playback frameworks, dav1d build, app build or simulator boot. This is
the narrow native GPU investigation step before an expensive IPA build.
"""
import json
from pathlib import Path
import subprocess
from checkpoint_compression_sources import prepare

root=Path(__file__).resolve().parents[1]
source=root/'build/checkpoint/source'
prepare(root,source,root/'dist/native-probe-notices')
output=root/'build/checkpoint/iphoneos';output.mkdir(parents=True,exist_ok=True)
shader='#include <metal_stdlib>\nusing namespace metal;\n'
for name in ('metal-zstd-core.h','metal-zstd-parallel.h','metal-zstd-input.h'):
    shader+=(root/'vendor/checkpoint'/name).read_text()+'\n'
wrapper=(root/'vendor/checkpoint/metal-zstd.metal').read_text()
for name in ('metal-zstd-core.h','metal-zstd-parallel.h','metal-zstd-input.h'):
    wrapper=wrapper.replace('#include "'+name+'"','')
shader+=wrapper
(output/'metal-zstd-shader.h').write_text('static const char neo_mzstd_shader_source[] = '+json.dumps(shader)+';\n')
subprocess.run(['python3','-u',str(root/'scripts/metal-zstd-smoke.py')],check=True)
