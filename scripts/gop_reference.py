"""Small private image references for displayed-buffer seek verification.

Decode once per movie on the PC. References are measured pixels, never a guessed
timestamp from the decoder queue. No source paths are serialized.
"""
import base64,re,subprocess

def references(movie, positions, fps, ffmpeg, origin=0):
    tolerance=max(.03,2/fps)
    windows='+'.join(f'between(t,{x+origin-tolerance:.6f},{x+origin+tolerance:.6f})' for x in positions)
    result=subprocess.run([str(ffmpeg),'-hide_banner','-loglevel','info','-i',str(movie),'-map','0:v:0','-an','-sn',
        '-vf',f"select='{windows}',scale=32:18:flags=lanczos,format=rgb24,showinfo",'-fps_mode','passthrough','-f','rawvideo','pipe:1'],capture_output=True,timeout=1200,check=True)
    stamps=[float(x)-origin for x in re.findall(rb'\bn:\s*\d+\s+pts:.*?pts_time:([\d.e+-]+)',result.stderr)]
    assert len(result.stdout)==len(stamps)*32*18*3,'Reference timestamp/pixel count mismatch'
    output=[]
    for i,pts in enumerate(stamps):
        rgb=result.stdout[i*1728:(i+1)*1728]
        luma=bytes(round(.2126*rgb[j]+.7152*rgb[j+1]+.0722*rgb[j+2]) for j in range(0,len(rgb),3))
        for target in positions:
            if abs(pts-target)<=tolerance:
                output.append(dict(target=target,pts=pts,luma=base64.b64encode(luma).decode('ascii')))
    assert all(any(x['target']==t for x in output) for t in positions),'Missing reference position'
    return output
