"""Independent macOS tooling: lipo, otool and codesign entitlement parsing.

codesign verification diagnostics are retained for both original and candidate;
macOS acceptance is distinct from the RootHide iOS loading environment.
"""
from pathlib import Path
import json, plistlib, subprocess, tempfile
import build as b

OUT=b.REPO/'artifacts/manager-trust'

def run(args):
    p=subprocess.run(args,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    return {'returncode':p.returncode,'stdout':p.stdout.decode(errors='replace'),'stderr':p.stderr.decode(errors='replace')},p.stdout

def inspect(raw,label,temp):
    result=[]; fat=temp/(label+'.fat'); fat.write_bytes(raw)
    info,_=run(['lipo','-info',str(fat)]); b.require(info['returncode']==0,'lipo could not parse binary')
    for arch,(sub,_,blob) in zip(['arm64','arm64e'],b.slices(raw)):
        thin=temp/(label+'.'+arch)
        r,_=run(['lipo',str(fat),'-thin',arch,'-output',str(thin)]); b.require(r['returncode']==0,'lipo failed to extract slice')
        b.require(thin.read_bytes()==blob,'lipo and Python disagree on slice bytes')
        otool,_=run(['otool','-l',str(thin)]); b.require(otool['returncode']==0,'otool parse failed')
        entitlements,xml=run(['codesign','-d','--entitlements',':-',str(thin)])
        b.require(entitlements['returncode']==0,'codesign could not read signature')
        parts=b.signature(blob)[1]
        if 5 in parts:
            expected=plistlib.loads(parts[5][1][8:])
            b.require(plistlib.loads(xml)==expected,'Apple entitlement parser disagrees')
        verify,_=run(['codesign','--verify','--strict','--verbose=4',str(thin)])
        result.append({'arch':arch,'subtype':hex(sub),'lipo':info,'otool':otool,'codesign_entitlements':entitlements,'codesign_verify':verify,'hashes':b.verify_signature(blob)})
    return result

def main():
    report={}
    with tempfile.TemporaryDirectory() as d:
        temp=Path(d)
        for kind,original,pattern,exe in [
            ('inject',b.ROOT/'vendor/inject-3.2.1-5.deb','cn.zqbb.inject.manager_*.deb','Applications/RootHideInject.app/RootHideInject'),
            ('blacklist',b.REPO/'Application/Dopamine/Resources/roothideapp.deb','com.roothide.manager_*.deb','Applications/RootHide.app/RootHide')]:
            candidates=list(OUT.glob(pattern)); b.require(len(candidates)==1,'Expected one candidate')
            _,old=b.deb_read(original.read_bytes()); _,new=b.deb_read(candidates[0].read_bytes())
            before=inspect(old[exe][1],kind+'-original',temp)
            after=inspect(new[exe][1],kind+'-candidate',temp)
            for orig,candidate in zip(before,after):
                b.require(orig['codesign_verify']['returncode']==candidate['codesign_verify']['returncode'],'Candidate changed Apple signature verification outcome')
            report[kind]={'original':before,'candidate':after}
        report['hook']=inspect((b.ROOT/'vendor/DetectionTrustHook.dylib').read_bytes(),'hook',temp)
    (OUT/'apple-inspection.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
    print('PASS: both slices independently parsed; Apple entitlement output matches; code and special-slot hashes verified')
    for kind in ('inject','blacklist'):
        print(kind,[(x['arch'],x['codesign_verify']['returncode'],x['codesign_verify']['stderr'].strip()) for x in report[kind]['candidate']])

if __name__=='__main__': main()
