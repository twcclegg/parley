import numpy as np, sys
from PIL import Image
OUT=sys.argv[1]; SS=2; N=1024*SS
y,x=np.mgrid[0:N,0:N].astype(np.float64)/SS+0.5/SS
S=0.84
def V(px,py): return 512+(px-512)*S, 512+(py-473.3)*S
def sd_rrect(x,y,x0,y0,x1,y1,r):
    cx,cy=(x0+x1)/2,(y0+y1)/2; hx,hy=(x1-x0)/2-r,(y1-y0)/2-r
    qx,qy=np.abs(x-cx)-hx,np.abs(y-cy)-hy
    return np.hypot(np.maximum(qx,0),np.maximum(qy,0))+np.minimum(np.maximum(qx,qy),0)-r
def sd_tri(x,y,p):
    d=np.full(x.shape,1e9); s=np.ones(x.shape)
    for i in range(3):
        (ax,ay),(bx,by)=p[i],p[(i+1)%3]
        ex,ey=bx-ax,by-ay; wx,wy=x-ax,y-ay
        t=np.clip((wx*ex+wy*ey)/(ex*ex+ey*ey),0,1)
        d=np.minimum(d,np.hypot(wx-ex*t,wy-ey*t))
        c1=(y>=ay); c2=(y<by); c3=(ex*wy>ey*wx)
        flip=(c1&c2&c3)|(~c1&~c2&~c3); s=np.where(flip,-s,s)
    return s*d
def ss(e0,e1,v): t=np.clip((v-e0)/(e1-e0),0,1); return t*t*(3-2*t)
def smin(a,b,k):
    h=np.clip(0.5+0.5*(b-a)/k,0,1); return b*(1-h)+a*h-k*h*(1-h)
x0,y0=V(166,196); x1,y1=V(858,722)
tri=[V(605.8,600),V(268,868),V(326.7,600)]
d=smin(sd_rrect(x,y,x0,y0,x1,y1,166*S),sd_tri(x,y,tri),30)
def aa(d): return np.clip(0.5-d*SS,0,1)
L=np.array([-0.45,-0.75,0.5]); L/=np.linalg.norm(L)
def save(rgb,a,name):
    img=np.dstack([np.clip(rgb,0,1),np.clip(a,0,1)])
    img=img.reshape(1024,SS,1024,SS,4).mean(axis=(1,3))
    # premultiplied mean -> fine for mostly-opaque edges
    Image.fromarray((img*255+0.5).astype(np.uint8),"RGBA").save(f"{OUT}/{name}.png")

def blur(a,r):
    r=int(r*SS)
    for ax in (0,1):
        c=np.cumsum(np.pad(a,[(r+1,r)] if False else ([(r+1,r),(0,0)] if ax==0 else [(0,0),(r+1,r)]),mode='edge'),axis=ax)
        a=((np.take(c,range(2*r+1,c.shape[ax]),axis=ax)-np.take(c,range(0,c.shape[ax]-2*r-1),axis=ax))/(2*r+1))
    return a
# ---- bubble: bevelled glass
B=34.0; inside=np.clip(-d/B,0,1); h=np.sin(inside*np.pi/2)
h=blur(blur(h,6),6)
gy,gx=np.gradient(h*B, 1/SS)
n=np.dstack([-gx,-gy,np.ones_like(gx)]); n/=np.linalg.norm(n,axis=2,keepdims=True)
diff=np.clip(n@L,0,1); hv=L+np.array([0,0,1]); hv/=np.linalg.norm(hv)
spec=np.clip(n@hv,0,1)**40
fres=(1-n[...,2])**1.5
cream=np.array([0.985,0.985,0.98])
vert=np.clip((y-y0)/(y1-y0),0,1)[...,None]
rgb=cream*(1.0-0.04*vert)*(0.94+0.08*diff[...,None])
rgb=rgb+spec[...,None]*0.6
edge=np.exp(-np.clip(-d,0,None)/3.0)*aa(d)
top=np.clip(-n[...,1]*1.5+0.4,0.25,1)
rgb=rgb+(edge*top)[...,None]*0.4
# Siri-like rainbow shimmer in the bevel: hue sweeps around the edge and across its width
def hsv(h,s_,v):
    h=(h%1)*6; i=np.floor(h).astype(int)%6; f=h-np.floor(h)
    p_=v*(1-s_); q=v*(1-s_*f); t=v*(1-s_*(1-f))
    r=np.choose(i,[v,q,p_,p_,t,v]); g=np.choose(i,[t,v,v,q,p_,p_]); b_=np.choose(i,[p_,p_,t,v,v,q])
    return np.dstack([r,g,b_])
# hue follows the angle around the bubble's middle, with a whole number of turns so it
# joins up, rather than the surface normal, which jumps where the tail meets the bubble
bcx,bcy=(x0+x1)/2,(y0+y1)/2
ang=np.arctan2(y-bcy,(x-bcx)*0.75)/(2*np.pi)
w=blur(blur(np.clip(-d,0,80),5),5)
hue=0.62+ang*2.0+w/38.0
bev=np.exp(-((w-14)/10)**2)*aa(d)
# strongest where light would refract: the lower edge, and a softer pass along the top
where=0.35+0.65*ss(0.45,1.0,(y-y0)/(y1-y0))+0.25*ss(0.4,0.0,(y-y0)/(y1-y0))
irid=hsv(hue,0.75*np.ones_like(hue),np.ones_like(hue))
k=(bev*where*0.42)[...,None]
rgb=rgb*(1-k)+irid*k+k*0.15
# warm light the orb throws onto the glass beneath it
ocx,ocy=V(512,459)
glow=np.exp(-(((x-ocx-10)/90)**2+((y-ocy-55)/60)**2))*0.14
rgb=rgb+glow[...,None]*(np.array([0xD9,0x77,0x57])/255-0.55)
shadow=np.exp(-(((x-ocx-12)/70)**2+((y-ocy-30)/55)**2))*0.07
rgb=rgb-shadow[...,None]
alpha=aa(d)*0.94
save(rgb,alpha,"middle")

# ---- orb: polished solid glass sphere
def ss(e0,e1,v): t=np.clip((v-e0)/(e1-e0),0,1); return t*t*(3-2*t)
def orb(cx,cy,R):
    dx,dy=(x-cx)/R,(y-cy)/R; r2=dx*dx+dy*dy; rho=np.sqrt(r2)
    th=np.degrees(np.arctan2(dy,dx))  # 0 = right, -90 = top
    nz=np.sqrt(np.clip(1-r2,0,1)); n=np.dstack([dx,dy,nz])
    orange=np.array([0xD9,0x77,0x57])/255
    deep=np.array([0.26,0.07,0.04])
    light=np.array([1.0,0.80,0.66])
    # body: lit core fading to deep edges, darker at upper left (away from the glow)
    depth=nz**1.1
    rgb=deep+(orange-deep)*depth[...,None]
    # light refracted through the sphere pools at the bottom
    pool=np.exp(-((dx*0.9)**2/0.30+((dy-0.55)**2)/0.10))
    rgb=rgb+(light-orange)*pool[...,None]*0.75
    core=np.exp(-((dx+0.05)**2+(dy-0.15)**2)/0.25)*0.18
    rgb=rgb+orange*core[...,None]
    # bright caustic rim along the bottom inside edge
    cau=np.exp(-((rho-0.88)/0.05)**2)*ss(0.1,0.7,dy)
    rgb=rgb+light*cau[...,None]*0.55
    # broad window reflection: a crescent along the upper left
    def arc(r0,r1,t0,t1,soft):
        band=ss(r0-soft,r0+soft,rho)*(1-ss(r1-soft,r1+soft,rho))
        mid=(t0+t1)/2; half=(t1-t0)/2
        win=ss(0,0.35,np.clip(1-np.abs(th-mid)/half,0,1))
        return band*win
    c1=arc(0.76,0.95,-172,-98,0.012)*(0.7+0.3*ss(0.76,0.9,rho))
    c2=arc(0.80,0.95,-70,-32,0.012)*0.9
    sheen=np.exp(-((dx+0.15)**2/0.28+(dy+0.55)**2/0.04))*0.30
    spot=np.exp(-((dx+0.40)**2+(dy+0.38)**2)/0.007)*1.0
    refl=np.clip(c1*1.0+c2*0.85+sheen+spot,0,1.2)
    rgb=rgb*(1-0.6*np.clip(refl,0,1)[...,None])+refl[...,None]*np.array([1,0.98,0.96])
    # thin specular edge
    edge=np.exp(-((rho-0.985)/0.012)**2)*0.35
    rgb=rgb+edge[...,None]
    return rgb, aa((rho-1)*R)
cx,cy=V(512,459); R=64*S
rgb,alpha=orb(cx,cy,R)
save(rgb,alpha,"front")
# a big standalone render to judge the look
if len(sys.argv)>2:
    pass
