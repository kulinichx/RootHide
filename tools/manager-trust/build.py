"""Build pinned Trust candidates; no device changes or package-script execution.

Preserves the input's non-CMS signing format and recomputes page hashes.
This is not an Apple developer signature or proof of device acceptance.
"""
from pathlib import Path
import argparse, copy, gzip, hashlib, io, json, math, plistlib, re, struct, tarfile

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[1]
STAMP = 1793059200
INJECT_SHA = '13d2a8dfc0d6496cbf4e472ddb1314643b95f1d611fa0dbebf5506fa8c9e8bfa'
HOOK_SHA = '1885d0b5f9cf8af4d6fb2c7038231722e84b4ebc170a8ee03f3ee9672d702d4d'
BLACK_SHA = '5392005d50c2a3e6189545e408aa4723bad401995ec508efcb48010c53d57f28'
INSTALL_NAME = '@executable_path/DetectionTrustHook.dylib'

def require(ok, message):
    if not ok: raise ValueError(message)

def digest(data): return hashlib.sha256(data).hexdigest()

def read_pinned(path, expected):
    data = path.read_bytes()
    require(digest(data)==expected, f'Unaudited input: {path}')
    return data

def ar_read(raw):
    require(raw[:8]==b'!<arch>\n','Not a Debian ar archive')
    result={}; pos=8
    while pos < len(raw):
        h=raw[pos:pos+60]
        require(len(h)==60 and h[58:]==bytes([96,10]),'Invalid ar header')
        name=h[:16].decode('ascii').strip().rstrip('/'); n=int(h[48:58])
        require(name not in result and pos+60+n<=len(raw),'Invalid ar member')
        result[name]=raw[pos+60:pos+60+n]; pos+=60+n+n%2
    require(pos==len(raw),'Truncated ar archive')
    require(result.get('debian-binary')==b'2.0\n','Unsupported Debian format')
    return result

def tar_read(raw):
    result={}
    with tarfile.open(fileobj=io.BytesIO(raw),mode='r:*') as tf:
        for m in tf.getmembers():
            name=m.name.removeprefix('./')
            require(name not in result and not name.startswith('/') and '..' not in name.split('/'),'Unsafe/duplicate tar member')
            result[name]=(copy.copy(m),tf.extractfile(m).read() if m.isfile() else None)
    return result

def deb_read(raw):
    ar=ar_read(raw)
    def part(prefix):
        found=[v for k,v in ar.items() if k.startswith(prefix)]
        require(len(found)==1,'Ambiguous Debian member'); return tar_read(found[0])
    return part('control.tar'),part('data.tar')

def tar_write(members):
    out=io.BytesIO()
    with tarfile.open(fileobj=out,mode='w',format=tarfile.GNU_FORMAT) as tf:
        for name,(original,data) in members.items():
            m=copy.copy(original); m.name=name; m.size=len(data) if data is not None else 0
            tf.addfile(m,io.BytesIO(data) if data is not None else None)
    return gzip.compress(out.getvalue(),compresslevel=9,mtime=0)

def deb_write(control,payload):
    out=bytearray(b'!<arch>\n')
    for name,data in [('debian-binary',b'2.0\n'),('control.tar.gz',tar_write(control)),('data.tar.gz',tar_write(payload))]:
        header=f'{name+chr(47):<16}{STAMP:<12}{0:<6}{0:<6}{100644:<8}{len(data):<10}'.encode('ascii')+bytes([96,10])
        require(len(header)==60,'Invalid ar header size'); out+=header+data
        if len(data)%2: out+=b'\n'
    return bytes(out)

def slices(raw):
    require(raw[:4]==bytes.fromhex('cafebabe'),'Expected universal Mach-O')
    count=struct.unpack_from('>I',raw,4)[0]; require(count==2,'Expected two slices')
    result=[]
    for i in range(count):
        cpu,sub,off,size,align=struct.unpack_from('>IIIII',raw,8+20*i)
        require(cpu==0x100000c and off+size<=len(raw),'Unsupported slice')
        require(off%(1<<align)==0,'Unaligned Mach-O slice')
        result.append((sub,off,raw[off:off+size]))
    require([a[0] for a in result]==[0,0x80000002],'Unexpected architecture order')
    require(result[0][1]+len(result[0][2])<=result[1][1],'Overlapping slices')
    return result

def commands(blob):
    require(blob[:4]==bytes.fromhex('cffaedfe'),'Not a 64-bit Mach-O')
    n,size=struct.unpack_from('<II',blob,16); pos=32; result=[]
    for _ in range(n):
        cmd,length=struct.unpack_from('<II',blob,pos)
        require(length>=8 and length%8==0 and pos+length<=32+size,'Invalid load command')
        result.append((cmd,pos,length)); pos+=length
    require(pos==32+size,'Invalid command size'); return result

def sections(blob):
    result=[]
    for cmd,pos,_ in commands(blob):
        if cmd!=0x19: continue
        count=struct.unpack_from('<I',blob,pos+64)[0]
        for i in range(count):
            s=pos+72+80*i
            name,seg,va,size,off=struct.unpack_from('<16s16sQQI',blob,s)
            flags=struct.unpack_from('<I',blob,s+64)[0]
            result.append((seg.rstrip(b'\0').decode(),name.rstrip(b'\0').decode(),off,size,flags))
    return result

def libraries(blob):
    result=[]
    for cmd,pos,length in commands(blob):
        if cmd not in (0xc,0x80000018,0x8000001f,0xd): continue
        n=struct.unpack_from('<I',blob,pos+8)[0]
        name=blob[pos+n:pos+length].split(b'\0',1)[0].decode()
        result.append((cmd,name))
    return result

def signature(blob):
    sigcmd=[pos for cmd,pos,_ in commands(blob) if cmd==0x1d]
    require(len(sigcmd)==1,'Expected one code signature')
    off,size=struct.unpack_from('<II',blob,sigcmd[0]+8)
    require(off+size<=len(blob),'Signature exceeds slice')
    magic,length,count=struct.unpack_from('>III',blob,off)
    require(magic==0xfade0cc0 and length<=size,'Invalid signature superblob')
    parts={}
    for i in range(count):
        slot,rel=struct.unpack_from('>II',blob,off+12+8*i)
        magic,n=struct.unpack_from('>II',blob,off+rel)
        require(rel>=12+8*count and rel+n<=length and slot not in parts,'Invalid signature blob')
        parts[slot]=(off+rel,blob[off+rel:off+rel+n])
    require(0x10000 not in parts,'CMS signature cannot be preserved after modification')
    return off,parts

def verify_signature(blob):
    off,parts=signature(blob); report=[]
    for slot,(pos,cd) in parts.items():
        if slot!=0 and not 0x1000<=slot<0x1006: continue
        magic,length,version,flags,hashoff,ident,ns,nc,limit=struct.unpack_from('>9I',cd)
        hs,ht,platform,power=struct.unpack_from('4B',cd,36)
        require(magic==0xfade0c02 and version in (0x20400,0x20500),'Unsupported CodeDirectory')
        require(ht in (1,2) and hs=={1:20,2:32}[ht],'Unsupported hash type')
        require(power==12 and limit==off and nc==math.ceil(limit/(1<<power)),'Unexpected code limit/page count')
        require(hashoff>=ns*hs and hashoff+nc*hs==length,'Unexpected hash layout')
        require(struct.unpack_from('>I',cd,44)[0]==0,'Scatter signatures unsupported')
        h=lambda data: hashlib.new('sha1' if ht==1 else 'sha256',data).digest()
        for i in range(nc):
            require(cd[hashoff+i*hs:hashoff+(i+1)*hs]==h(blob[i*4096:min(limit,(i+1)*4096)]),f'Code page hash mismatch: slot={slot}, page={i}')
        for i in range(1,ns+1):
            value=cd[hashoff-i*hs:hashoff-(i-1)*hs]
            require(value==(h(parts[i][1]) if i in parts else bytes(hs)),f'Special-slot mismatch: {i}')
        report.append({'slot':slot,'flags':flags,'hash_type':ht,'code_pages':nc,'special_slots':ns,'code_limit':limit,'cdhash':h(cd)[:20].hex()})
    require(report,'Missing CodeDirectory'); return report

def add_hook(raw):
    output=bytearray(raw); reports=[]
    for sub,off,old in slices(raw):
        before=verify_signature(old); blob=bytearray(old)
        n,size=struct.unpack_from('<II',blob,16); end=32+size
        require(not any('DetectionTrust' in name for _,name in libraries(old)),'Already adapted')
        name=INSTALL_NAME.encode()+b'\0'; length=(24+len(name)+7)&~7
        first=min(s[2] for s in sections(old) if s[2]>0)
        require(end+length<=first and not any(blob[end:end+length]),'Insufficient zero header padding')
        cmd=struct.pack('<6I',0xc,length,24,0,0,0)+name
        blob[end:end+length]=cmd.ljust(length,b'\0')
        struct.pack_into('<II',blob,16,n+1,size+length)
        sigoff,parts=signature(blob)
        require(set(parts)=={0,2,5,7},'Unexpected signing structure for pinned Inject')
        pos,cd=parts[0]; hashoff,_,_,nc,limit=struct.unpack_from('>5I',cd,16)
        require(cd[36:40]==bytes([32,2,0,12]),'Unexpected signing hash format')
        for i in range(nc):
            blob[pos+hashoff+i*32:pos+hashoff+(i+1)*32]=hashlib.sha256(blob[i*4096:min(limit,(i+1)*4096)]).digest()
        after=verify_signature(blob)
        require(blob[first:sigoff]==old[first:sigoff],'Code/data/linkedit changed')
        require(libraries(blob)==libraries(old)+[(0xc,INSTALL_NAME)],'Library order changed')
        newparts=signature(blob)[1]
        for s in (2,5,7): require(newparts[s][1]==signature(old)[1][s][1],'Signing metadata changed')
        require(len(blob)==len(old),'Slice size changed')
        output[off:off+len(blob)]=blob
        reports.append({'subtype':hex(sub),'unchanged_code_data_and_linkedit':True,'unchanged_entitlements_requirements':True,'before':before,'after':after,'load_command_bytes':length})
    return bytes(output),reports

def set_content(members,name,data):
    meta,_=members[name]; members[name]=(meta,data)

def make_package(source,version,display,kind,hook=None):
    controls,payload=deb_read(source); original=copy.deepcopy(payload)
    app='Applications/'+('RootHideInject.app' if kind=='inject' else 'RootHide.app')
    exe=app+'/'+('RootHideInject' if kind=='inject' else 'RootHide')
    audit=[]
    if hook is not None:
        main,audit=add_hook(payload[exe][1]); set_content(payload,exe,main)
        meta=tarfile.TarInfo(app+'/DetectionTrustHook.dylib'); meta.mode=0o755; meta.uid=meta.gid=0; meta.mtime=STAMP
        payload[meta.name]=(meta,hook)
    else:
        for sub,_,blob in slices(payload[exe][1]):
            audit.append({'subtype':hex(sub),'signature':verify_signature(blob),'main_binary_unchanged':True})
    for name,(_,data) in payload.items():
        require('RCInjectAnalysis' not in name,'Analysis payload found')
        if name==exe:
            require(not any('RCInjectAnalysis' in n for _,_,b in slices(data) for _,n in libraries(b)),'Analysis dependency found')
    plistpath=app+'/Info.plist'; info=plistlib.loads(payload[plistpath][1])
    info['RHUpstreamVersion']=info['CFBundleShortVersionString']; info['RHTrustRevision']=1
    info['CFBundleShortVersionString']=display
    fmt=plistlib.FMT_BINARY if payload[plistpath][1].startswith(b'bplist') else plistlib.FMT_XML
    set_content(payload,plistpath,plistlib.dumps(info,fmt=fmt,sort_keys=False))
    control=controls['control'][1].decode()
    control=re.sub(r'^Version: .*$',f'Version: {version}',control,flags=re.M)
    size=sum(len(d) for _,d in payload.values() if d is not None)
    control=re.sub(r'^Installed-Size: .*$',f'Installed-Size: {math.ceil(size/1024)}',control,flags=re.M)
    control=re.sub(r'^Description: .*$',"Description: RootHide manager with detection trust preferences\n Trust edition: user-confirmed BindFS mount trust and VPN/proxy warning preferences.",control,flags=re.M)
    set_content(controls,'control',control.encode())
    encoded=deb_write(controls,payload); c2,p2=deb_read(encoded)
    require(c2['postinst'][1]==deb_read(source)[0]['postinst'][1],'postinst changed')
    changes=[name for name in original if original[name][1]!=p2[name][1]]
    expected=[exe,plistpath] if hook is not None else [plistpath]
    require(set(changes)==set(expected),'Unexpected payload change')
    for name,(meta,_) in original.items():
        require((meta.mode,meta.uid,meta.gid,meta.linkname,meta.type)==(p2[name][0].mode,p2[name][0].uid,p2[name][0].gid,p2[name][0].linkname,p2[name][0].type),'File metadata changed')
    return encoded,{'package_version':version,'display_version':display,'sha256':digest(encoded),'size':len(encoded),'changed_payload':changes,'added_payload':sorted(set(p2)-set(original)),'postinst_unchanged':True,'existing_file_permissions_unchanged':True,'macho':audit}

def build(out):
    official=read_pinned(ROOT/'vendor/inject-3.2.1-5.deb',INJECT_SHA)
    hook=read_pinned(ROOT/'vendor/DetectionTrustHook.dylib',HOOK_SHA)
    black=read_pinned(REPO/'Application/Dopamine/Resources/roothideapp.deb',BLACK_SHA)
    hookcheck=[{'subtype':hex(sub),'signature':verify_signature(blob)} for sub,_,blob in slices(hook)]
    out.mkdir(parents=True,exist_ok=True); reports={}
    for name,source,version,display,kind,h in [
        ('cn.zqbb.inject.manager_3.2.1-5+trust1_iphoneos-arm64e.deb',official,'3.2.1-5+trust1','3.2.1-5 · Trust','inject',hook),
        ('com.roothide.manager_1.3.9+trust1_iphoneos-arm64e.deb',black,'1.3.9+trust1','1.3.9 · Trust','blacklist',None)]:
        data,report=make_package(source,version,display,kind,h)
        (out/name).write_bytes(data); require(digest((out/name).read_bytes())==report['sha256'],'Output verification failed')
        reports[name]=report; print(name,len(data),digest(data))
    report={'inputs':{'inject':INJECT_SHA,'hook':HOOK_SHA,'blacklist':BLACK_SHA},'hook_verification':hookcheck,'outputs':reports,'device_tested':False,'signing_note':'Existing non-CMS format retained. Every code page and embedded special-slot hash verified. Not an Apple developer signature or proof of device acceptance.'}
    (out/'verification.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
    (out/'SHA256SUMS.txt').write_text(''.join(f"{r['sha256']}  {n}\n" for n,r in reports.items()),encoding='ascii')
    return report

if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--output',type=Path,default=REPO/'artifacts/2026-10-27-manager-trust')
    build(parser.parse_args().output)
