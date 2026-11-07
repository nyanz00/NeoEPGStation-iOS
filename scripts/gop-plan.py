"""Read-only packet-key analysis for the local foreground GOP benchmark.

The output is private test input, not an application resource. No movie path,
program title, server URL or credentials are written into the plan.
"""
import argparse,json,random,shutil,statistics,subprocess
from pathlib import Path
from gop_reference import references

p=argparse.ArgumentParser();p.add_argument('directory',type=Path);p.add_argument('output',type=Path);p.add_argument('--ffprobe',default=shutil.which('ffprobe'));p.add_argument('--ffmpeg',default=shutil.which('ffmpeg'));a=p.parse_args()
if not a.ffprobe:raise SystemExit('Supply --ffprobe with the installed ffprobe executable')
if not a.ffmpeg:a.ffmpeg=str(Path(a.ffprobe).with_name('ffmpeg.exe' if str(a.ffprobe).endswith('.exe') else 'ffmpeg'))
profiles=[];movies=[]
for movie in sorted(a.directory.iterdir()):
 if not movie.is_file() or movie.suffix.lower() not in ('.mkv','.mp4','.mov'):continue
 meta=json.loads(subprocess.check_output([a.ffprobe,'-v','error','-show_streams','-show_format','-of','json',str(movie)],timeout=60))
 video=next(s for s in meta['streams'] if s['codec_type']=='video');fps=video['avg_frame_rate'].split('/');fps=float(fps[0])/float(fps[1])
 packets=json.loads(subprocess.check_output([a.ffprobe,'-v','error','-select_streams','v:0','-show_packets','-show_entries','packet=pts_time,flags','-of','json',str(movie)],timeout=300))['packets']
 origin=float(video.get('start_time',0));keys=sorted(set(round(float(x['pts_time'])-origin,6) for x in packets if 'K' in x.get('flags','') and 'pts_time' in x and float(x['pts_time']) >= origin))
 gaps=[b-a for a,b in zip(keys,keys[1:])];assert gaps
 label=movie.stem.rsplit('-',1)[-1]
 if not (label.lower()=='default' or label.lower().startswith('gop') and label[3:].isdigit()):label=f'profile-{len(profiles)+1}'
 profiles.append(dict(label=label,bytes=movie.stat().st_size,duration=float(meta['format']['duration'])-origin,fps=fps,keys=keys,
  sourceTimeOrigin=origin,codec=video['codec_name'],pixelFormat=video.get('pix_fmt'),width=video['width'],height=video['height'],gapMedian=statistics.median(gaps),gapMax=max(gaps)))
 movies.append(movie)
assert profiles and len(set(x['bytes'] for x in profiles))==len(profiles),'Input sizes must identify profiles uniquely'
duration=min(x['duration'] for x in profiles);assert duration>100
rng=random.Random(20261107)
targets=[round(40+(i+.2+.6*rng.random())*(duration-80)/24,3) for i in range(24)]
positions=sorted(set(targets+[round(t+d,3) for t in targets for d in (-10,10)]))
for movie,profile in zip(movies,profiles):
 print('Preparing image references:',profile['label'],flush=True)
 profile['references']=references(movie,positions,profile['fps'],a.ffmpeg,profile['sourceTimeOrigin'])
a.output.parent.mkdir(parents=True,exist_ok=True)
a.output.write_text(json.dumps(dict(schema=1,targets=targets,profiles=profiles),ensure_ascii=False,separators=(',',':'))+'\n',encoding='utf-8')
print('Saved',len(profiles),'profiles and',len(targets),'common target positions to',a.output)
