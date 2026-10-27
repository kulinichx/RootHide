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
        entitlement_path=temp/(label+'.'+arch+'.entitlements')
        # Apple TN3125: modern codesign defaults to a human-readable DER dump.
        entitlements,stdout=run(['/usr/bin/codesign','-d','--entitlements',str(entitlement_path),'--xml',str(thin)])
        parts=b.signature(blob)[1]
        apple_xml=None
        if entitlement_path.exists():
            xml=entitlement_path.read_bytes()
            if xml[:4]==bytes.fromhex('fade7171'): xml=xml[8:]
            apple_xml=plistlib.loads(xml)
        if 5 in parts:
            expected=plistlib.loads(parts[5][1][8:])
            ldid,xml=run(['ldid','-e',str(thin)])
            b.require(ldid['returncode']==0,'ldid could not extract entitlements')
            b.require(plistlib.loads(xml)==expected,'Independent ldid entitlement parser disagrees')
            if apple_xml is not None: b.require(apple_xml==expected,'Apple entitlement parser disagrees')
            # The supplied upstream may have XML that Apple's modern parser rejects.
            # Record this baseline limitation, never label it successful verification.
            if apple_xml is None:
                b.require('invalid entitlements blob' in entitlements['stderr'],'Unexpected missing Apple entitlement output')
        else: ldid=None
        verify,_=run(['/usr/bin/codesign','--verify','--strict','--verbose=4',str(thin)])
        result.append({'arch':arch,'subtype':hex(sub),'lipo':info,'otool':otool,'codesign_entitlements':entitlements,'apple_xml_extracted':apple_xml is not None,'ldid_entitlements':ldid,'codesign_verify':verify,'hashes':b.verify_signature(blob)})
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
                b.require(orig['apple_xml_extracted']==candidate['apple_xml_extracted'],'Candidate changed Apple entitlement extraction outcome')
                normalize=lambda text: text.replace('original','candidate')
                b.require(normalize(orig['codesign_verify']['stderr'])==candidate['codesign_verify']['stderr'],'Candidate changed Apple verification diagnostic')
                b.require(normalize(orig['codesign_entitlements']['stderr'])==candidate['codesign_entitlements']['stderr'],'Candidate changed Apple entitlement diagnostic')
            report[kind]={'original':before,'candidate':after}
        report['hook']=inspect((b.ROOT/'vendor/DetectionTrustHook.dylib').read_bytes(),'hook',temp)
    (OUT/'apple-inspection.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
    print('PASS: both slices parsed with Apple tools; ldid entitlements match; code/special-slot hashes verified; Apple diagnostics match upstream')
    for kind in ('inject','blacklist'):
        print(kind,[(x['arch'],x['codesign_verify']['returncode'],x['codesign_verify']['stderr'].strip()) for x in report[kind]['candidate']])

if __name__=='__main__': main()
