"""Downloads public-domain and CC0 photos from Wikimedia Commons for the demo library.

    python3 -I fetch_photos.py <demo>/corpus/Photos "dog running on beach:2" "pizza:1" ...

Only files whose license metadata says public domain or CC0 are kept. Credits are written to
<demo>/CREDITS.json. Review every photo before using it: drop off-topic ones and any that show
identifiable people.
"""
import json, sys, os, re, urllib.request, urllib.parse, time
UA={'User-Agent':'GlintDemoBuilder/1.0 (vikramcse.10@gmail.com)'}
API='https://commons.wikimedia.org/w/api.php'
def get(params):
    url=API+'?'+urllib.parse.urlencode(params)
    with urllib.request.urlopen(urllib.request.Request(url,headers=UA),timeout=30) as r: return json.load(r)
out=sys.argv[1]; terms=sys.argv[2:]
credits=[]
cpath=os.path.join(out,'..','..','CREDITS.json')
if os.path.exists(cpath): credits=json.load(open(cpath))
have={c['file'] for c in credits}
for spec in terms:
    term,count=spec.rsplit(':',1); count=int(count); got=0
    d=get({'action':'query','format':'json','generator':'search','gsrsearch':f'{term} filetype:bitmap','gsrnamespace':6,'gsrlimit':40,
           'prop':'imageinfo','iiprop':'url|extmetadata|size','iiurlwidth':1600})
    pages=sorted(d.get('query',{}).get('pages',{}).values(), key=lambda p:p.get('index',0))
    for p in pages:
        if got>=count: break
        ii=p['imageinfo'][0]; md=ii.get('extmetadata',{})
        lic=md.get('LicenseShortName',{}).get('value','')
        if not re.search(r'public domain|^pd|cc0',lic,re.I): continue
        if ii.get('width',0)<1000 or ii.get('mime','image/jpeg') not in ('image/jpeg',): 
            if not ii['url'].lower().endswith(('.jpg','.jpeg')): continue
        name=re.sub(r'[^A-Za-z0-9]+','-',term).strip('-').lower()+f'-{got+1}.jpg'
        if name in have: got+=1; continue
        req=urllib.request.Request(ii.get('thumburl',ii['url']),headers=UA)
        data=urllib.request.urlopen(req,timeout=60).read()
        if not data[:3]==b'\xff\xd8\xff': continue
        open(os.path.join(out,name),'wb').write(data)
        credits.append({'file':name,'title':p['title'],'source':ii['descriptionurl'],'license':lic,
                        'artist':re.sub('<[^>]+>','',md.get('Artist',{}).get('value',''))[:120]})
        got+=1; time.sleep(0.3)
    print(f'{term}: {got}')
json.dump(credits,open(cpath,'w'),indent=1)
