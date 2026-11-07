"""Small private image references for displayed-buffer seek verification.

Decode once per movie on the PC. References are measured pixels, never a guessed
timestamp from the decoder queue. No source paths are serialized.
"""
import base64,re,subprocess

def references(movie, positions, fps, ffmpeg, origin=0):
    tolerance=max(.03,2/fps)
    windows='+'.join(f'between(t,{x+origin-tolerance:.6f},{x+origin+tolerance:.6f})' for x in positions)
    # CI downsamples in linear light, then the app reads back sRGB. Match that
    # operation, not swscale's default gamma-encoded YUV resize (which differs
    # substantially around coloured edges). Untagged SDR buffers may be treated
    # as sRGB or BT.709 by the display service; retain both labelled references.
    decoders=[('srgb',"if(lte(val/65535,0.04045),val/12.92,pow((val/65535+0.055)/1.055,2.4)*65535)"),
              ('bt709',"if(lte(val/65535,0.081),val/4.5,pow((val/65535+0.099)/1.099,1/0.45)*65535)")]
    encoded="if(lte(val/65535,0.0031308),val*12.92,(1.055*pow(val/65535,1/2.4)-0.055)*65535)"
    def lut(expression):return "lutrgb="+':'.join(f"{c}='{expression}'" for c in 'rgb')
    filters=f"[0:v:0]select='{windows}',scale=in_color_matrix=bt709:out_color_matrix=bt709,format=rgb48le,split=2[c0][c1];"
    for index,(_,decoded) in enumerate(decoders):
        filters+=f"[c{index}]"+lut(decoded)+",scale=32:18:flags=lanczos,format=rgb48le,"+lut(encoded)+f",format=rgb24[r{index}];"
    filters+='[r0][r1]hstack=inputs=2,showinfo[out]'
    result=subprocess.run([str(ffmpeg),'-hide_banner','-loglevel','info','-i',str(movie),'-filter_complex',filters,'-map','[out]','-an','-sn',
        '-fps_mode','passthrough','-f','rawvideo','pipe:1'],capture_output=True,timeout=1200,check=True)
    stamps=[float(x)-origin for x in re.findall(rb'\bn:\s*\d+\s+pts:.*?pts_time:([\d.e+-]+)',result.stderr)]
    assert len(result.stdout)==len(stamps)*64*18*3,'Reference timestamp/pixel count mismatch'
    output=[]
    for i,pts in enumerate(stamps):
        frame=result.stdout[i*3456:(i+1)*3456]
        for variant,(name,_) in enumerate(decoders):
            rgb=b''.join(frame[row*192+variant*96:row*192+(variant+1)*96] for row in range(18))
            luma=bytes(round(.2126*rgb[j]+.7152*rgb[j+1]+.0722*rgb[j+2]) for j in range(0,len(rgb),3))
            for target in positions:
                if abs(pts-target)<=tolerance:
                    output.append(dict(target=target,pts=pts,luma=base64.b64encode(luma).decode('ascii'),transfer=name))
    assert all(any(x['target']==t for x in output) for t in positions),'Missing reference position'
    return output
