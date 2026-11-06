// Development-only oracle. Execute the corresponding Web implementation itself,
// with deterministic font metrics, to compare native layout independently of
// CoreText/Canvas rasterizer differences. No Node runtime ships in the app.
import {stripTypeScriptTypes} from 'node:module';
import {readFileSync,writeFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
const source=readFileSync(process.argv[2],'utf8');
const web=await import('data:text/javascript;base64,'+Buffer.from(stripTypeScriptTypes(source)).toString('base64'));
const header=`[Script Info]
PlayResX: 960
PlayResY: 540
[V4+ Styles]
Format: Name,Fontname,Fontsize,PrimaryColour,BackColour,OutlineColour,ScaleX,ScaleY,Spacing,Bold,Italic,Underline,StrikeOut,Alignment,MarginL,MarginR,MarginV,Outline
Style: Default,Yu Gothic,46,&H0000FFFF,&H80000000,&H00000000,100,100,4,-1,0,0,0,1,0,0,0,2
Style: Ruby,Arial,18,&H00FFFFFF,&H80000000,&H00000000,100,100,0,0,0,0,0,1,0,0,0,1
[Events]
Format: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text
`;
const event=(text,style='Default',layer=0,start=0,end=4)=>`Dialogue: ${layer},0:00:0${start}.00,0:00:0${end}.00,${style},,0,0,0,,${text}`;
const scripts=[
 ['spacing-decoration',event('{\\pos(160,430)}本文　{\\c&HFFFFFF&}白い文字{\\b1}太字')],
 ['ruby-unrelated',event('{\\pos(160,420)}本文の表示')+'\n'+event('{\\pos(170,394)}よみ','Ruby')+'\n'+event('{\\pos(600,60)}別の字幕','Ruby',0,1,3)],
 ['layers',event('{\\pos(160,430)}下の字幕')+'\n'+event('{\\pos(160,430)\\1a&HFF&}上の背景領域','Default',2)],
 ['inline-scale',event('{\\pos(160,430)}最初{\\fs23\\fscx80\\fscy120\\fsp2}次{\\r}戻る')],
 ['motion-fade',event('{\\move(80,400,500,300,500,2500)\\fad(1000,1000)\\4a&H40&}動く字幕')],
 ['srt-collision',event('{\\an2}一つ目の字幕')+'\n'+event('{\\an2}二つ目の字幕')],
 ['wrapping',event('{\\an7}長い字幕の折返しを確認する文字列です'.repeat(3),'Ruby')],
 ['explicit-lines',event('{\\pos(200,250)\\an5}上の行\\N下の行{\\i1\\u1\\s1}装飾')],
 ['graphemes',event('{\\pos(160,430)}か\u3099と𠮷と👨‍👩‍👧')]
];
class Context {
 constructor(){this.s={font:'20px sans-serif',fillStyle:'#ffffff',strokeStyle:'#000000',globalAlpha:1,lineWidth:2,x:0,y:0,sx:1,sy:1};this.stack=[];this.ops=[];this.path=[];}
 save(){this.stack.push({...this.s});} restore(){this.s=this.stack.pop();}
 translate(x,y){this.s.x+=x*this.s.sx;this.s.y+=y*this.s.sy;} scale(x,y){this.s.sx*=x;this.s.sy*=y;}
 measureText(t){const em=Number(this.s.font.match(/([\d.]+)px/)[1]);return {width:em*.6,actualBoundingBoxAscent:em*.75,actualBoundingBoxDescent:em*.15};}
 beginPath(){this.path=[];} rect(x,y,w,h){this.path.push([x,y,w,h]);}
 fill(){this.ops.push({kind:'band',boxes:this.path,color:this.s.fillStyle,opacity:this.s.globalAlpha});}
 fillRect(x,y,w,h){if(this.s.sx===1&&this.s.sy===1&&this.s.x===0&&this.s.y===0)this.ops.push({kind:'band',boxes:[[x,y,w,h]],color:this.s.fillStyle,opacity:this.s.globalAlpha});}
 strokeText(){} fillText(text,x,y){this.ops.push({kind:'text',text,x:this.s.x+x,y:this.s.y+y,sx:this.s.sx,sy:this.s.sy,color:this.s.fillStyle,outlineColor:this.s.strokeStyle,outline:this.s.lineWidth/2,opacity:this.s.globalAlpha,bold:/\bbold\b/.test(this.s.font),italic:/\bitalic\b/.test(this.s.font)});}
}
for(const key of ['font','fillStyle','strokeStyle','globalAlpha','lineWidth'])Object.defineProperty(Context.prototype,key,{get(){return this.s[key]},set(v){this.s[key]=v}});
const cases=[];
for(const [name,body]of scripts){const text=header+body,doc=web.parseAssSubtitle(text);for(const time of [0,0.75,1.5,3.5,4]){const ctx=new Context();web.drawAssSubtitles(ctx,doc,time,false,'sans-serif');cases.push({name:name+'-'+time,text,time,width:doc.width,height:doc.height,ops:ctx.ops});}}
writeFileSync(process.argv[3],JSON.stringify({sourceSHA256:createHash('sha256').update(source).digest('hex'),cases},null,2)+'\n');
console.log('Web oracle:',cases.length,'cases');
