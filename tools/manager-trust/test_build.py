"""Package integrity regression checks, including intentionally damaged inputs."""
import copy, hashlib, plistlib, struct, unittest
from pathlib import Path
import build as b

class TrustPackages(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.upstream=b.read_pinned(b.ROOT/'vendor/inject-3.2.1-5.deb',b.INJECT_SHA)
        cls.hook=b.read_pinned(b.ROOT/'vendor/DetectionTrustHook.dylib',b.HOOK_SHA)
        cls.black=b.read_pinned(b.REPO/'Application/Dopamine/Resources/roothideapp.deb',b.BLACK_SHA)
        cls.executable=b.deb_read(cls.upstream)[1]['Applications/RootHideInject.app/RootHideInject'][1]
        cls.patched,_=b.add_hook(cls.executable)

    def test_only_header_padding_and_code_hashes_change(self):
        for (sub,off,old),(_,_,new) in zip(b.slices(self.executable),b.slices(self.patched)):
            end=32+struct.unpack_from('<I',old,20)[0]
            new_command=[(pos,length) for command,pos,length in b.commands(new) if pos==end]
            self.assertEqual(len(new_command),1)
            command_size=new_command[0][1]
            pos,cd=b.signature(old)[1][0]
            hashoff,_,_,count,_=struct.unpack_from('>5I',cd,16)
            allowed=lambda p: 16<=p<24 or end<=p<end+command_size or pos+hashoff<=p<pos+hashoff+32*count
            self.assertEqual(len(old),len(new))
            for i,(x,y) in enumerate(zip(old,new)):
                if x!=y: self.assertTrue(allowed(i),(hex(sub),i))
            for _,_,offset,size,flags in b.sections(old):
                if offset: self.assertEqual(old[offset:offset+size],new[offset:offset+size])
            self.assertEqual(b.libraries(new),b.libraries(old)+[(12,b.INSTALL_NAME)])

    def test_corrupt_code_is_rejected(self):
        blob=bytearray(b.slices(self.patched)[0][2]); blob[16384]^=1
        with self.assertRaisesRegex(ValueError,'Code page hash mismatch'): b.verify_signature(blob)

    def test_corrupt_entitlements_are_rejected(self):
        blob=bytearray(b.slices(self.patched)[0][2]); position,_=b.signature(blob)[1][5]; blob[position+20]^=1
        with self.assertRaisesRegex(ValueError,'Special-slot mismatch'): b.verify_signature(blob)

    def test_second_patch_is_rejected(self):
        with self.assertRaisesRegex(ValueError,'Already adapted'): b.add_hook(self.patched)

    def test_nonzero_padding_is_rejected(self):
        blob=bytearray(self.executable); _,offset,slice_=b.slices(blob)[0]
        end=32+struct.unpack_from('<I',slice_,20)[0]; blob[offset+end]=1
        with self.assertRaises(ValueError): b.add_hook(blob)

    def test_reproducible_packages_preserve_data_and_settings(self):
        for source,kind,version,display,hook in [
            (self.upstream,'inject','3.2.1-5+trust1','3.2.1-5 · Trust',self.hook),
            (self.black,'blacklist','1.3.9+trust1','1.3.9 · Trust',None)]:
            a,report=b.make_package(source,version,display,kind,hook)
            again,_=b.make_package(source,version,display,kind,hook)
            self.assertEqual(a,again)
            oldc,oldp=b.deb_read(source); c,p=b.deb_read(a)
            self.assertEqual(c['postinst'][1],oldc['postinst'][1])
            self.assertFalse(set(c)-set(oldc))
            self.assertFalse(any('RCInjectAnalysis' in name for name in p))
            self.assertFalse(any(name.startswith(('var/','private/')) for name in p))
            for name,(_,raw) in p.items():
                if name.endswith('/Info.plist'):
                    before=plistlib.loads(oldp[name][1]); after=plistlib.loads(raw)
                    self.assertEqual(after.pop('RHUpstreamVersion'),before['CFBundleShortVersionString'])
                    self.assertEqual(after.pop('RHTrustRevision'),1)
                    self.assertEqual(after['CFBundleShortVersionString'],display)
                    after['CFBundleShortVersionString']=before['CFBundleShortVersionString']
                    self.assertEqual(before,after)
                elif raw and raw[:4]==bytes.fromhex('cafebabe'):
                    for _,_,slice_ in b.slices(raw): b.verify_signature(slice_)
                else: self.assertEqual(oldp[name][1],raw)
            if kind=='blacklist':
                exe='Applications/RootHide.app/RootHide'
                self.assertEqual(p[exe][1],oldp[exe][1])
            else:
                self.assertEqual(p['Applications/RootHideInject.app/DetectionTrustHook.dylib'][1],self.hook)

if __name__=='__main__': unittest.main(verbosity=2)
