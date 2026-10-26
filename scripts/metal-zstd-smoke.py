"""Check the complete shipping GPU Zstd encoder before expensive app builds."""
import json
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[1]
out=root/'build/checkpoint/metal-zstd-smoke';out.mkdir(exist_ok=True)
cc=subprocess.check_output(['xcrun','--sdk','macosx','--find','clang'],text=True).strip()
sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
base=[cc,'-isysroot',sdk,'-O2','-DNEO_MZSTD_NATIVE_DEBUG','-I'+str(root/'vendor/checkpoint'),'-I'+str(root/'build/checkpoint/source/include')]
for source,name,extra in [
    ('build/checkpoint/source/src/neo_zstd.c','decoder',[]),
    ('vendor/checkpoint/metal-zstd-format.c','format',[]),
    ('vendor/checkpoint/metal-zstd.m','metal',['-fobjc-arc','-fblocks','-I'+str(root/'build/checkpoint/iphoneos')]),
]:
    subprocess.run(base+extra+['-c',str(root/source),'-o',str(out/(name+'.o'))],check=True)
binary=out/'metal-zstd-test'
subprocess.run(base+[str(root/'tests/metal-zstd-metal.c'),str(out/'decoder.o'),str(out/'format.o'),str(out/'metal.o'),
    '-framework','Foundation','-framework','Metal','-o',str(binary)],check=True)
result=json.loads(subprocess.check_output([str(binary)],text=True,timeout=180))
assert result.get('gpuUnavailable') or result.get('cases')==24 and result.get('images')==72 and result.get('byteExact') and result.get('compressedImages',0)>0
if not result.get('gpuUnavailable'):
    # Same input, same matcher and GPU; stop before the app build if the new
    # cooperative encoder regresses on the native correctness/performance probe.
    assert result['parallelWallMs']<result['legacy277WallMs'],result
    assert result['parallelToLegacy277Size']<1.03,result
    assert len(result['parallelStageMs'])==8 and result['preprocessingImages']==20
result['devicePerformanceVerified']=False
result['scope']='macOS Metal execution of shipping match/parse/Huffman/FSE/frame assembly; standard Zstd CPU decode'
(root/'dist/metal-zstd-verification.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result),flush=True)
