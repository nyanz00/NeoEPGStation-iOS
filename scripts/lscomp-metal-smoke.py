"""Check the shipping Metal bridge on the runner before expensive app builds."""
import json
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[1]
out=root/'build/checkpoint/metal-smoke';out.mkdir(exist_ok=True)
cc=subprocess.check_output(['xcrun','--sdk','macosx','--find','clang'],text=True).strip()
sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
base=[cc,'-isysroot',sdk,'-O2','-I'+str(root/'vendor/checkpoint')]
for source,name,extra in [
    ('vendor/checkpoint/lscomp-format.c','format',[]),
    ('vendor/checkpoint/lscomp-metal.m','metal',['-fobjc-arc','-fblocks','-I'+str(root/'build/checkpoint/iphoneos')]),
]:
    subprocess.run(base+extra+['-c',str(root/source),'-o',str(out/(name+'.o'))],check=True)
binary=out/'lscomp-metal-test'
subprocess.run(base+[str(root/'tests/lscomp-metal.c'),str(out/'format.o'),str(out/'metal.o'),
    '-framework','Foundation','-framework','Metal','-o',str(binary)],check=True)
result=json.loads(subprocess.check_output([str(binary)],text=True,timeout=120))
assert result.get('gpuUnavailable') or result.get('cases')==24 and result.get('byteExact')
result['devicePerformanceVerified']=False
result['scope']='macOS Metal byte-exact check of shipping bridge and four GPU passes'
(root/'dist/lscomp-metal-verification.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result),flush=True)
