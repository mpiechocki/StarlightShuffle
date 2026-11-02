"""Editable pastel lobby. Python 3 + numpy; Pillow is only needed for preview.
Run: python build_lobby.py. Units: metres. GLB exports use glTF Y-up.
Each asset is a named parent with separate editable mesh components.
"""
from pathlib import Path
import json, struct, math, zipfile
import numpy as np

OUT=Path(__file__).resolve().parent
ASSETS=OUT/'assets'; ASSETS.mkdir(exist_ok=True)
MATS={
 'cream':('#fff2df',.78), 'lavender':('#b6a0dc',.83),
 'pink':('#efb5d2',.82), 'blue':('#accee9',.8),
 'navy':('#302955',.9), 'gold':('#d7ad68',.35),
 'green':('#6b9e7b',.88), 'darkgreen':('#45795c',.9),
 'screen':('#696bb3',.45), 'glow':('#fff0b0',.5),
 'purple':('#8d75bd',.85), 'white':('#fff9f2',.8),
 'peach':('#efbd9c',.8), 'soil':('#655044',1.)}
def rot(a):
 x,y,z=a; cx,sx=math.cos(x),math.sin(x); cy,sy=math.cos(y),math.sin(y); cz,sz=math.cos(z),math.sin(z)
 return np.array([[cz,-sz,0],[sz,cz,0],[0,0,1]])@np.array([[cy,0,sy],[0,1,0],[-sy,0,cy]])@np.array([[1,0,0],[0,cx,-sx],[0,sx,cx]])
class Asset:
 def __init__(self,name): self.name=name; self.parts=[]
 def add(self,name,v,f,mat,p=(0,0,0),r=(0,0,0)):
  v=np.array(v,float)@rot(r).T+np.array(p); self.parts.append((name,v,np.array(f,int),mat)); return self

def box(a,name,p,s,mat='cream',radius=.08,r=(0,0,0)):
 h=np.array(s)/2; radius=min(radius,min(h)*.95); core=h-radius
 v=[]; f=[]; n=4
 for axis in range(3):
  for sign in [-1,1]:
   k=len(v); other=[i for i in range(3) if i!=axis]
   for j in range(n+1):
    for i in range(n+1):
     q=np.zeros(3); q[axis]=sign*h[axis]; q[other[0]]=h[other[0]]*(i*2/n-1); q[other[1]]=h[other[1]]*(j*2/n-1)
     c=np.clip(q,-core,core); d=q-c; v.append(c+d/np.linalg.norm(d)*radius)
   for j in range(n):
    for i in range(n):
     t=k+j*(n+1)+i; tri=[[t,t+1,t+n+2],[t,t+n+2,t+n+1]]
     for face in tri:
      va,vb,vc=[v[u] for u in face]
      if np.cross(vb-va,vc-va)[axis]*sign<0: face.reverse()
      f.append(face)
 return a.add(name,v,f,mat,p,r)

def sphere(a,name,p,s,mat='cream',r=(0,0,0),seg=16,rings=10):
 v=[];f=[]
 for j in range(rings+1):
  t=math.pi*j/rings
  for i in range(seg):
   ph=2*math.pi*i/seg; v.append([s[0]*math.sin(t)*math.cos(ph)/2,s[1]*math.sin(t)*math.sin(ph)/2,s[2]*math.cos(t)/2])
 for j in range(rings):
  for i in range(seg):
   b=j*seg+i;c=j*seg+(i+1)%seg;d=c+seg;e=b+seg
   if j>0:f.append([b,c,e])
   if j<rings-1:f.append([c,d,e])
 # reverse sphere winding
 f=[t[::-1] for t in f]
 return a.add(name,v,f,mat,p,r)

def cyl(a,name,p,rad,height,mat='gold',r=(0,0,0),top=None,seg=20):
 if top is None:top=rad
 v=[];f=[]
 for z,rr in [(-height/2,rad),(height/2,top)]:
  v += [[rr*math.cos(i*2*math.pi/seg),rr*math.sin(i*2*math.pi/seg),z] for i in range(seg)]
 v += [[0,0,-height/2],[0,0,height/2]]
 for i in range(seg):
  j=(i+1)%seg;f += [[i,j,seg+j],[i,seg+j,seg+i],[2*seg,j,i],[2*seg+1,seg+i,seg+j]]
 return a.add(name,v,f,mat,p,r)

def rod(a,name,p,q,rad=.025,mat='gold'):
 p=np.array(p);q=np.array(q);d=q-p;L=np.linalg.norm(d)
 r=(0,math.acos(d[2]/L),math.atan2(d[1],d[0]))
 return cyl(a,name,(p+q)/2,rad,L,mat,r)

def poly(a,name,points,p,depth,mat='cream',r=(0,0,0)):
 # Extrude a 2D X/Z outline along Y, independently editable solid.
 points=list(points)
 area=sum(points[i][0]*points[(i+1)%len(points)][1]-points[(i+1)%len(points)][0]*points[i][1] for i in range(len(points)))
 if area<0:points.reverse()
 n=len(points); v=[[x,-depth/2,z] for x,z in points]+[[x,depth/2,z] for x,z in points]
 # Ear clipping preserves the concave crescent cushion instead of filling its cutout.
 def cross2(a,b,c):return (b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0])
 remaining=list(range(n));caps=[]
 while len(remaining)>3:
  found=False
  for k,j in enumerate(remaining):
   i=remaining[k-1];l=remaining[(k+1)%len(remaining)];aa,bb,cc=points[i],points[j],points[l]
   if cross2(aa,bb,cc)<=1e-10:continue
   inside=False
   for t in remaining:
    if t in (i,j,l):continue
    q=points[t]
    if cross2(aa,bb,q)>=-1e-10 and cross2(bb,cc,q)>=-1e-10 and cross2(cc,aa,q)>=-1e-10:inside=True;break
   if inside:continue
   caps.append([i,j,l]);remaining.pop(k);found=True;break
  if not found:raise ValueError('Cannot triangulate '+name)
 caps.append(remaining);f=[]
 for i,j,k in caps:f.extend([[i,j,k],[n+k,n+j,n+i]])
 for i in range(n):
  j=(i+1)%n;f += [[i,n+i,n+j],[i,n+j,j]]
 return a.add(name,v,f,mat,p,r)
def star(a,name,p,size=.3,mat='gold',depth=.06,r=(0,0,0)):
 pts=[]
 for i in range(10):
  t=math.pi/2+i*math.pi/5; rr=size*(.5 if i%2==0 else .23);pts.append((math.cos(t)*rr,math.sin(t)*rr))
 return poly(a,name,pts,p,depth,mat,r)
def cloud(a,name,p,s=(.8,.3,.45),mat='cream'):
 for i,(x,z,k) in enumerate([(-.3,0,.6),(-.13,.12,.8),(.08,.14,1),(.32,.01,.65)]):
  sphere(a,name+str(i),(p[0]+x*s[0],p[1],p[2]+z*s[2]),(s[0]*k*.65,s[1],s[2]*k),mat)
FONT={
'A':['01110','10001','10001','11111','10001','10001','10001'],
'R':['11110','10001','10001','11110','10100','10010','10001'],
'C':['01111','10000','10000','10000','10000','10000','01111'],
'D':['11110','10001','10001','10001','10001','10001','11110'],
'E':['11111','10000','10000','11110','10000','10000','11111'],
'S':['01111','10000','10000','01110','00001','00001','11110'],
'H':['10001','10001','10001','11111','10001','10001','10001'],
'O':['01110','10001','10001','10001','10001','10001','01110'],
'P':['11110','10001','10001','11110','10000','10000','10000'],
'L':['10000','10000','10000','10000','10000','10000','11111'],
'B':['11110','10001','10001','11110','10001','10001','11110']}
def text(a,word,p,height=.25,mat='gold'):
 u=height/7;start=p[0]-(len(word)*6-1)*u/2
 # Combine all pixel glyphs into ONE editable text mesh per sign.
 tmp=Asset('text')
 for c,ch in enumerate(word):
  for j,row in enumerate(FONT.get(ch,FONT['O'])):
   for i,on in enumerate(row):
    if on=='1':box(tmp,'pixel',(start+(c*6+i)*u,p[1],p[2]+(3-j)*u),(u*.96,.028,u*.96),mat,.004)
 vs=[];fs=[]
 for _,v,f,_ in tmp.parts:fs.extend((f+len(vs)).tolist());vs.extend(v.tolist())
 a.add(word+' editable mesh lettering',vs,fs,mat)

def wall(navy=False):
 a=Asset('Navy constellation wall' if navy else 'Lavender molded wall')
 box(a,'wall core',(0,0,1.8),(3.2,.22,3.6),'navy' if navy else 'lavender',.025)
 for x in [-1.51,1.51]:
  box(a,'pilaster',(x,-.17,1.8),(.17,.17,3.6),'cream',.035)
  box(a,'column foot',(x,-.2,.15),(.27,.23,.3),'cream',.035)
 for z in [.12,3.49]:box(a,'cornice',(0,-.16,z),(3.2,.23,.19),'cream',.035)
 if navy:
  pts=[(-1.1,2.9),(-.5,2.4),(.15,2.7),(.8,1.9),(.4,1.2),(1.15,.7)]
  for i,(x,z) in enumerate(pts):
   star(a,'constellation star',(x,-.15,z),.12)
   if i:rod(a,'constellation line',(pts[i-1][0],-.14,pts[i-1][1]),(x,-.14,z),.009)
 else:
  for x in [-1.22,1.22]:box(a,'inset frame',(x,-.14,1.8),(.035,.03,2.65),'gold',.005)
  for z in [.47,3.13]:box(a,'inset frame',(0,-.14,z),(2.47,.03,.035),'gold',.005)
  star(a,'wall star',(0,-.22,2.1),.36)
 return a
def doorway():
 a=Asset('Arcade open doorway')
 # Rounded opening corners formed by progressively stepping inset trim.
 for x in [-1.64,1.64]:
  box(a,'lavender jamb',(x,0,1.8),(.42,.38,3.6),'lavender',.07)
  box(a,'cream doorway trim',(x- math.copysign(.1,x),-.23,1.55),(.22,.16,3.1),'cream',.09)
  box(a,'jamb foot',(x,-.09,.13),(.58,.52,.26),'cream',.06)
 box(a,'header',(0,0,3.3),(3.7,.38,.6),'lavender',.12)
 box(a,'upper cream lintel',(0,-.24,3.03),(3.12,.16,.25),'cream',.12)
 for x in [-1.39,1.39]:sphere(a,'rounded inner corner',(x,-.24,2.98),(.38,.17,.38),'cream')
 text(a,'ARCADE',(0,-.24,3.4),.24)
 for x in [-1.1,1.1]:star(a,'marquee star',(x,-.27,3.4),.24)
 return a
def leaderboard():
 a=Asset('Leaderboard display')
 box(a,'outer frame',(0,0,1.2),(2.2,.22,2.4),'cream',.18)
 box(a,'lavender bezel',(0,-.13,1.2),(2.02,.08,2.22),'lavender',.14)
 box(a,'blue display',(0,-.18,1.2),(1.85,.04,2.04),'screen',.12)
 text(a,'LEADERBOARD',(0,-.215,2.02),.135,'white')
 for i in range(5):
  z=1.63-i*.3;star(a,'rank star',(-.65,-.23,z),.12,'glow')
  box(a,'score track',(.1,-.22,z),(1.1,.035,.11),'purple',.04)
  box(a,'score fill',(-.1-i*.05,-.245,z),(.7-i*.1,.025,.07),'blue',.03)
 for x in [-.32,0,.32]:star(a,'crown star',(x,-.1,2.48),.25 if x==0 else .18)
 return a
def sofa():
 a=Asset('Cloud sofa')
 box(a,'curved seat base',(0,0,.42),(3.5,1.15,.52),'cream',.25)
 for i in range(7):
  x=(i-3)*.48;y=.36-.12*(x/1.5)**2
  sphere(a,'scalloped back cushion',(x,y,.99),(.65,.43,1.18),'cream',r=(0,-x*.1,0))
 for x in [-1.64,1.64]:sphere(a,'padded arm',(x,-.03,.65),(.42,1.05,.65),'cream')
 for x in [-1.4,1.4]:
  for y in [-.36,.36]:cyl(a,'gold foot',(x,y,.12),.1,.24)
 for x in [-.95,.5]:star(a,'star pillow',(x,-.02,.94),.62,'pink',.2)
 # Crescent is an explicit curved strip with closed ends.
 pts=[]
 for i in range(33):
  t=math.radians(65+230*i/32);pts.append((math.cos(t)*.33,math.sin(t)*.36))
 for i in range(32,-1,-1):
  t=math.radians(65+230*i/32);pts.append((.13+math.cos(t)*.25,math.sin(t)*.29))
 poly(a,'crescent cushion',pts,(-.23,-.08,1.04),.19,'gold')
 controller(a,(1.02,-.15,.94),.7)
 return a
def controller(a,p,scale=1):
 x,y,z=p;s=scale
 sphere(a,'controller cushion center',p,(s,.24*s,.48*s),'blue')
 for xx in [-.36,.36]:sphere(a,'controller cushion grip',(x+xx*s,y,z-.13*s),(.38*s,.26*s,.51*s),'blue',r=(0,xx*.7,0))
 box(a,'D-pad horizontal',(x-.25*s,y-.15*s,z+.015*s),(.22*s,.035*s,.07*s),'pink',.015)
 box(a,'D-pad vertical',(x-.25*s,y-.15*s,z+.015*s),(.07*s,.035*s,.22*s),'pink',.015)
 for xx,zz in [(0,.08),(.1,0),(0,-.08),(-.1,0)]:sphere(a,'controller button',(x+(.26+xx)*s,y-.15*s,z+zz*s),(.065*s,.035*s,.065*s),'cream')
def bench():
 a=Asset('Pink tufted bench');box(a,'seat',(0,0,.53),(2.7,.85,.25),'pink',.12)
 box(a,'gold seat rim',(0,0,.36),(2.72,.84,.08),'gold',.035)
 for x in [-1.13,1.13]:
  for y in [-.29,.29]:cyl(a,'leg',(x,y,.18),.07,.36,'gold',top=.11)
 for i in range(7):
  for y in [-.22,.22]:sphere(a,'tuft button',(-1.05+i*.35,y,.659),(.055,.055,.018),'purple')
 return a
def table():
 a=Asset('Cloud coffee table')
 for x,y in [(-.55,0),(-.25,.16),(.15,.16),(.48,0),(.2,-.2),(-.25,-.2)]:sphere(a,'cloud tabletop',(x,y,.48),(.75,.64,.12),'cream')
 for x in [-.5,.5]:
  for y in [-.18,.18]:cyl(a,'table leg',(x,y,.24),.055,.45)
 return a
def ottoman():
 a=Asset('Blue round ottoman')
 sphere(a,'ottoman body',(0,0,.25),(1.05,1.05,.43),'blue')
 cyl(a,'gold band',(0,0,.2),.49,.045)
 star(a,'top star',(0,0,.467),.22,'lavender',.015,r=(math.pi/2,0,0))
 return a
def sidetable():
 a=Asset('Star pedestal side table')
 cyl(a,'plinth',(0,0,.06),.26,.12)
 cyl(a,'tapered pedestal',(0,0,.39),.23,.6,'lavender',top=.12)
 cyl(a,'tabletop',(0,0,.73),.35,.1,'cream')
 star(a,'inlaid top star',(0,0,.785),.2,'gold',.015,r=(math.pi/2,0,0))
 return a
def shop():
 a=Asset('Pastel shop stall')
 box(a,'counter body',(0,0,.57),(2.7,.85,1.14),'lavender',.18)
 box(a,'counter front',(0,-.45,.6),(2.47,.08,.82),'cream',.15)
 box(a,'countertop',(0,0,1.17),(2.88,1.0,.16),'cream',.12)
 for x in [-.8,0,.8]:star(a,'counter gold star',(x,-.505,.63),.25)
 for x in [-1.24,1.24]:cyl(a,'canopy post',(x,.23,1.67),.035,2.35)
 box(a,'back display',(0,.36,1.57),(2.3,.15,.85),'pink',.06)
 for z in [1.32,1.73,2.04]:box(a,'display shelf',(0,.2,z),(2.35,.4,.06),'cream',.02)
 for i in range(8):
  x=-1.25+i*.357;mat='pink' if i%2 else 'blue'
  box(a,'awning stripe',(x,.0,2.43),(.37,1.12,.15),mat,.07,r=(.13,0,0))
  sphere(a,'awning scallop',(x,-.51,2.34),(.36,.14,.22),mat)
 box(a,'shop sign',(0,.19,2.78),(1.65,.15,.48),'cream',.16)
 text(a,'SHOP',(0,.1,2.78),.28)
 star(a,'shop crown',(0,.1,3.1),.3)
 for i in range(5):box(a,'gift merchandise',(-.8+i*.4,.12,1.43),(.25,.22,.34),'pink' if i%2 else 'blue',.035)
 for x in [-.7,.65]:
  sphere(a,'toy body',(x,-.12,1.42),(.27,.22,.3),'peach' if x>0 else 'lavender')
  sphere(a,'toy head',(x,-.12,1.63),(.32,.25,.28),'peach' if x>0 else 'lavender')
  for ex in [-.07,.07]:sphere(a,'toy eye',(x+ex,-.245,1.65),(.025,.02,.035),'navy')
 for i in range(4):cyl(a,'arcade token',(.12,-.25,1.28+i*.025),.09,.025)
 return a
def arcade(blue=False):
 a=Asset('Blue arcade cabinet' if blue else 'Pink arcade cabinet');m='blue' if blue else 'pink'
 box(a,'cabinet lower',(0,.06,.64),(.76,.66,1.28),m,.07)
 box(a,'cabinet upper',(0,.21,1.5),(.76,.4,.78),m,.07)
 box(a,'screen bezel',(0,-.015,1.5),(.64,.09,.64),'cream',.04)
 box(a,'display',(0,-.07,1.5),(.5,.025,.48),'screen',.025)
 star(a,'pixel star',(0,-.09,1.5),.22,'glow')
 box(a,'control deck',(0,-.12,1.05),(.8,.63,.14),'cream',.05,r=(.13,0,0))
 cyl(a,'joystick stem',(-.19,-.25,1.19),.015,.17)
 sphere(a,'joystick knob',(-.19,-.25,1.28),(.11,.11,.11),'pink')
 for x in [.09,.24]:sphere(a,'button',(x,-.25,1.15),(.09,.09,.045),'blue' if not blue else 'pink')
 box(a,'marquee',(0,.14,2.04),(.84,.46,.28),m,.07)
 star(a,'marquee star',(0,-.105,2.04),.17,'glow')
 cyl(a,'stool foot',(0,-.83,.045),.21,.09)
 cyl(a,'stool stem',(0,-.83,.3),.04,.52)
 cyl(a,'stool seat',(0,-.83,.59),.24,.13,m)
 return a
def planter():
 a=Asset('Scalloped palm planter')
 sphere(a,'rounded pot',(0,0,.38),(.8,.8,.75),'lavender')
 cyl(a,'gold foot',(0,0,.08),.29,.1)
 cyl(a,'pot rim',(0,0,.66),.34,.1,'cream')
 cyl(a,'soil',(0,0,.71),.28,.015,'soil')
 for i in range(9):
  t=i*2.4;end=(.63*math.cos(t),.63*math.sin(t),1.15+(i%3)*.18)
  rod(a,'leaf stem',(0,0,.68),end,.018,'darkgreen')
  # Long elliptical leaves oriented outwards, deliberately simple game geometry.
  sphere(a,'palm leaf',(end[0]*.7,end[1]*.7,end[2]),(.19,.85,.045),'green',r=(.25,t, t-math.pi/2),seg=12,rings=6)
 return a
def lamp():
 a=Asset('Cloud floor lamp')
 cyl(a,'lamp foot',(0,0,.07),.25,.14,'lavender')
 rod(a,'upright',(0,0,.14),(0,0,2.0),.025)
 prev=(0,0,2.)
 for i in range(1,13):
  t=math.pi*i/12;p=(.33-.33*math.cos(t),0,2.+.33*math.sin(t));rod(a,'curved neck',prev,p,.025);prev=p
 cloud(a,'glowing cloud',(.66,0,1.9),(.65,.35,.35),'glow')
 return a
def sconce():
 a=Asset('Cloud wall sconce');rod(a,'wall arm',(0,.16,.2),(0,-.08,.2),.025);cloud(a,'cloud',(0,-.13,.28),(.55,.28,.3),'glow');return a
def ornaments():
 a=Asset('Star hanging light');rod(a,'cord',(0,0,.28),(0,0,1),.012);star(a,'star frame',(0,0,.25),.45);star(a,'emissive face',(0,-.04,.25),.36,'glow');return a
def shelf():
 a=Asset('Arched display shelf')
 box(a,'back',(0,.17,.9),(1.0,.12,1.65),'pink',.25)
 for x in [-.5,.5]:box(a,'shelf side',(x,0,.8),(.1,.4,1.6),'cream',.04)
 for z in [.13,.65,1.15,1.6]:box(a,'shelf board',(0,0,z),(1.1,.46,.08),'cream',.04)
 star(a,'crest star',(0,.1,1.85),.24)
 for i in range(4):box(a,'book',(-.32+i*.16,-.03,.88),(.12,.22,.36),'blue' if i%2 else 'lavender',.02,r=(0,-.08*i,0))
 return a
def window():
 a=Asset('Arched decorative window')
 box(a,'arched backing',(0,0,1.1),(.95,.12,2.2),'cream',.35)
 box(a,'pastel glass',(0,-.08,1.1),(.78,.04,1.98),'purple',.32)
 for z in [.7,1.3]:box(a,'crossbar',(0,-.12,z),(.78,.04,.045),'cream',.015)
 box(a,'mullion',(0,-.12,1.1),(.045,.04,1.98),'cream',.015)
 cloud(a,'window cloud',(.1,-.14,.85),(.45,.03,.15),'pink')
 star(a,'window star',(-.15,-.14,1.7),.16)
 return a
def smallprops():
 a=Asset('Tabletop flower vase and books')
 sphere(a,'vase',(0,0,.17),(.24,.24,.32),'cream')
 for i in range(5):
  t=i*2.4;x=.15*math.cos(t);y=.15*math.sin(t);z=.45+.06*(i%2)
  rod(a,'flower stem',(0,0,.25),(x,y,z),.008,'green')
  for k in range(5):
   u=k*2*math.pi/5;sphere(a,'flower petal',(x+.05*math.cos(u),y+.05*math.sin(u),z),(.075,.075,.035),'purple',seg=8,rings=6)
  sphere(a,'flower center',(x,y,z+.015),(.04,.04,.03),'gold',seg=8,rings=6)
 for i in range(2):box(a,'book',(.4,0,.045+i*.08),(.38,.28,.07),'pink' if i else 'blue',.02)
 return a
def floor():
 a=Asset('Floor and shallow cloud platform');box(a,'floor slab',(0,0,-.12),(16,10,.24),'lavender',.1)
 # deterministic scattered large pixel tiles with actual editable geometry
 rng=np.random.default_rng(6)
 for i in range(200):
  x=float(rng.uniform(-7.8,7.8));y=float(rng.uniform(-4.8,4.8))
  box(a,'pixel floor accent',(x,y,.008),(.17,.17,.012),['cream','pink','blue'][i%3],.002)
 for side in [-1,1]:
  for i in range(25):sphere(a,'shallow cloud edge',(-7.7+i*15.4/24,side*4.95,-.22),(.93,.55,.34),'cream')
  for i in range(15):sphere(a,'shallow side cloud',(side*7.9,-4.6+i*9.2/14,-.22),(.55,.95,.34),'cream')
 return a
def rug():
 a=Asset('Pixel moon rug');box(a,'rug',(0,0,.025),(6.5,3.45,.035),'purple',.04)
 for x in [-3.05,3.05]:box(a,'rug border',(x,0,.047),(.055,3.12,.006),'pink',.002)
 for y in [-1.55,1.55]:box(a,'rug border',(0,y,.047),(6.15,.055,.006),'pink',.002)
 for i in range(-6,7):
  for j in range(-6,7):
   if i*i+j*j<35 and (i-3)**2+(j+1)**2>28:
    box(a,'pixel crescent',(i*.1,j*.1,.05),(.1,.1,.008),'pink',.001)
 for x,y in [(-2,-.7),(1.7,.8),(2.1,-.7)]:star(a,'rug star',(x,y,.052),.4,'cream',.009,r=(math.pi/2,0,0))
 return a

def export_glb(path,placements):
 mats=[];matidx={}
 for name,(col,rough) in MATS.items():
  rgb=[int(col[i:i+2],16)/255 for i in (1,3,5)]
  matidx[name]=len(mats); m={'name':name,'pbrMetallicRoughness':{'baseColorFactor':rgb+[1],'roughnessFactor':rough,'metallicFactor':.45 if name=='gold' else 0},'doubleSided':False}
  if name=='glow':m['emissiveFactor']=[.5,.35,.13]
  mats.append(m)
 data=bytearray();views=[];access=[];meshes=[];nodes=[];roots=[]
 def acc(arr,typ,component,target):
  nonlocal data
  while len(data)%4:data+=b'\0'
  off=len(data);data+=arr.tobytes();idx=len(views);views.append({'buffer':0,'byteOffset':off,'byteLength':arr.nbytes,'target':target})
  a={'bufferView':idx,'componentType':component,'count':len(arr),'type':typ}
  if typ=='VEC3':a.update(min=arr.min(axis=0).tolist(),max=arr.max(axis=0).tolist())
  access.append(a);return len(access)-1
 for asset,p,rz in placements:
  parent=len(nodes);nodes.append({'name':asset.name,'children':[],'translation':list(p),'rotation':[0,0,math.sin(rz/2),math.cos(rz/2)]});roots.append(parent)
  for name,v,f,mat in asset.parts:
   # smooth normals computed from shared triangle vertices
   normals=np.zeros_like(v);fn=np.cross(v[f[:,1]]-v[f[:,0]],v[f[:,2]]-v[f[:,0]])
   for k in range(3):np.add.at(normals,f[:,k],fn)
   lens=np.linalg.norm(normals,axis=1);normals/=np.maximum(lens[:,None],1e-12)
   pa=acc(v.astype('<f4'),'VEC3',5126,34962);na=acc(normals.astype('<f4'),'VEC3',5126,34962);ia=acc(f.flatten().astype('<u4'),'SCALAR',5125,34963)
   meshes.append({'name':name,'primitives':[{'attributes':{'POSITION':pa,'NORMAL':na},'indices':ia,'material':matidx[mat]}]})
   nodes[parent]['children'].append(len(nodes));nodes.append({'name':name,'mesh':len(meshes)-1})
 # modelling convention Z-up -> standard glTF Y-up
 root=len(nodes);nodes.append({'name':'PASTEL_LOBBY_Zup_to_Yup','rotation':[-math.sqrt(.5),0,0,math.sqrt(.5)],'children':roots})
 doc={'asset':{'version':'2.0','generator':'Pastel Lobby editable procedural model'},'scene':0,'scenes':[{'nodes':[root]}],'nodes':nodes,'meshes':meshes,'materials':mats,'buffers':[{'byteLength':len(data)}],'bufferViews':views,'accessors':access}
 js=json.dumps(doc,separators=(',',':')).encode();js+=b' '*((-len(js))%4);data+=b'\0'*((-len(data))%4)
 total=12+8+len(js)+8+len(data)
 path.write_bytes(struct.pack('<4sII',b'glTF',2,total)+struct.pack('<I4s',len(js),b'JSON')+js+struct.pack('<I4s',len(data),b'BIN\0')+data)
 return {'file':path.name,'objects':sum(len(a.parts) for a,_,_ in placements),'triangles':sum(len(f) for a,_,_ in placements for _,v,f,m in a.parts)}

def preview(placements,path):
 from PIL import Image
 W,H=1400,1000;pixels=np.zeros((H,W,3),dtype=np.uint8);pixels[:]=[227,220,237];zbuffer=np.full((H,W),-np.inf)
 # elevated frontal orthographic camera, facing positive Y
 depth=np.array([.23,-.78,.58]);depth/=np.linalg.norm(depth);right=np.cross(np.array([0,0,1]),depth);right/=np.linalg.norm(right);up=np.cross(depth,right);light=np.array([-.4,-.6,.8]);light/=np.linalg.norm(light)
 scale=67
 for a,p,rz in placements:
  R=rot((0,0,rz))
  for _,v,f,m in a.parts:
   v=v@R.T+np.array(p);pts=np.column_stack([W/2+v@right*scale,H*.62-v@up*scale]);dep=v@depth
   col=MATS[m][0];rgb=np.array([int(col[i:i+2],16) for i in (1,3,5)])
   normals=np.zeros_like(v);fn=np.cross(v[f[:,1]]-v[f[:,0]],v[f[:,2]]-v[f[:,0]])
   for k in range(3):np.add.at(normals,f[:,k],fn)
   normals/=np.maximum(np.linalg.norm(normals,axis=1)[:,None],1e-12)
   lighting=.62+.38*np.maximum(0,normals@light)
   for face in f:
    vv=v[face];n=np.cross(vv[1]-vv[0],vv[2]-vv[0]);length=np.linalg.norm(n)
    if length<1e-9:continue
    n/=length
    if n@depth<=0:continue
    t=pts[face];x0=max(0,int(np.floor(t[:,0].min())));x1=min(W-1,int(np.ceil(t[:,0].max())));y0=max(0,int(np.floor(t[:,1].min())));y1=min(H-1,int(np.ceil(t[:,1].max())))
    if x0>x1 or y0>y1:continue
    X,Y=np.meshgrid(np.arange(x0,x1+1)+.5,np.arange(y0,y1+1)+.5)
    denom=(t[1,1]-t[2,1])*(t[0,0]-t[2,0])+(t[2,0]-t[1,0])*(t[0,1]-t[2,1])
    if abs(denom)<1e-10:continue
    b0=((t[1,1]-t[2,1])*(X-t[2,0])+(t[2,0]-t[1,0])*(Y-t[2,1]))/denom
    b1=((t[2,1]-t[0,1])*(X-t[2,0])+(t[0,0]-t[2,0])*(Y-t[2,1]))/denom;b2=1-b0-b1
    z=b0*dep[face[0]]+b1*dep[face[1]]+b2*dep[face[2]]
    region=zbuffer[y0:y1+1,x0:x1+1];mask=(b0>=-1e-6)&(b1>=-1e-6)&(b2>=-1e-6)&(z>region)
    if not mask.any():continue
    shade=b0*lighting[face[0]]+b1*lighting[face[1]]+b2*lighting[face[2]]
    colors=np.clip(shade[:,:,None]*rgb,0,255).astype(np.uint8);region[mask]=z[mask];pixels[y0:y1+1,x0:x1+1][mask]=colors[mask]
 Image.fromarray(pixels).save(path)

def main():
 kit={'arcade_doorway':doorway(),'leaderboard':leaderboard(),'lavender_wall':wall(),'constellation_wall':wall(True),'arched_window':window(),'shop_stall':shop(),'cloud_sofa':sofa(),'tufted_bench':bench(),'coffee_table':table(),'ottoman':ottoman(),'side_table':sidetable(),'display_shelf':shelf(),'pink_arcade':arcade(),'blue_arcade':arcade(True),'palm_planter':planter(),'cloud_floor_lamp':lamp(),'cloud_sconce':sconce(),'star_pendant':ornaments(),'tabletop_decor':smallprops(),'floor_cloud_platform':floor(),'moon_rug':rug()}
 pillow=Asset('Controller pillow');controller(pillow,(0,0,.3),1);kit['controller_pillow']=pillow
 manifest=[]
 for name,a in kit.items():manifest.append(export_glb(ASSETS/(name+'.glb'),[(a,(0,0,0),0)]))
 placements=[]
 def place(name,p=(0,0,0),r=0):placements.append((kit[name],p,r))
 place('floor_cloud_platform');place('moon_rug',(0,-.65,0))
 place('arcade_doorway',(0,4.8,0))
 for x in [-6.45,-3.25,3.25,6.45]:place('lavender_wall',(x,4.8,0))
 place('leaderboard',(-3.3,4.48,.72))
 for side in [-1,1]:
  for y in [-3.2,0,3.2]:place('constellation_wall',(side*7.9,y,0),-side*math.pi/2)
  for y in [-2.4,2.1]:place('arched_window',(side*7.73,y,.55),-side*math.pi/2)
 place('shop_stall',(-5.6,1.55,0),.12)
 place('cloud_sofa',(5.7,1.5,0),-.16)
 place('coffee_table',(5.2,-.1,0));place('tabletop_decor',(5.05,-.1,.55))
 place('ottoman',(6.1,-1,0));place('tufted_bench',(5.3,-3.4,0))
 place('side_table',(7.1,.0,0));place('star_pendant',(7.1,0,.78))
 place('palm_planter',(-6.7,-3.5,0));place('palm_planter',(4,3.75,0))
 place('cloud_floor_lamp',(6.3,3.4,0),math.pi)
 place('display_shelf',(-7,-.8,0))
 for x in [-2,2]:place('star_pendant',(x,4.48,2.3))
 for side in [-1,1]:
  for y in [-2,2]:place('cloud_sconce',(side*7.66,y,2.1),-side*math.pi/2)
 # A compact open arcade bay beyond doorway, keeping the lobby footprint readable.
 for i,x in enumerate([-1.1,-.36,.4,1.15]):place('blue_arcade' if i%2 else 'pink_arcade',(x,6.3,0))
 manifest.append(export_glb(OUT/'pastel_lobby.glb',placements))
 # separate laid-out catalog scene makes all assets easy to inspect in an editor
 catalog=[]
 for i,(name,a) in enumerate(kit.items()):
  if name=='floor_cloud_platform':continue
  catalog.append((a,((i%5)*5,(i//5)*6,0),0))
 manifest.append(export_glb(OUT/'asset_catalog.glb',catalog))
 (OUT/'manifest.json').write_text(json.dumps(manifest,indent=2))
 preview(placements,OUT/'model-preview.png')
 print(json.dumps({'assets':len(kit),'scene':manifest[-2],'catalog':manifest[-1]},indent=2))
if __name__=='__main__':main()
