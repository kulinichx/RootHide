"""Dyld install regression: real production helper with filesystem failure injection."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from test_rc9_services import extract, source

FILE='BaseBin/libjailbreak/src/basebin_gen.m'
class DyldContracts(unittest.TestCase):
    def test_install_reports_failures_and_rolls_back(self):
        body=extract(source(FILE),'static int install_generated_dyld')
        self.assertIn('moveItemAtPath:old toPath:patched',body)
        self.assertNotIn('removeItemAtPath:patched',body)
        for code in (5,6,7,8):self.assertIn(f'return {code}',body)
    def test_copy_errors_stop_generation(self):
        body=extract(source(FILE),'int basebin_generate')
        self.assertEqual(body.count('if (carbonCopy('),3)
        self.assertIn('return install_generated_dyld(',body)
    def test_failed_symbol_lookup_releases_macho(self):
        body=extract(source(FILE),'int apply_dyld_patch')
        failure=body.split('if (getAMFIAddr == 0)',1)[1].split('}',1)[0]
        self.assertIn('macho_free(dyldMacho)',failure)

PREFIX=r'''
#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
static NSMutableSet* files;
static NSString* failRemove;
static NSMutableSet* failMoves;
@interface TestFileManager : NSObject
+(instancetype)defaultManager;
-(BOOL)fileExistsAtPath:(NSString*)path;
-(BOOL)removeItemAtPath:(NSString*)path error:(NSError**)error;
-(BOOL)moveItemAtPath:(NSString*)path toPath:(NSString*)target error:(NSError**)error;
@end
@implementation TestFileManager
+(instancetype)defaultManager { static TestFileManager* fm; if(!fm)fm=[self new];return fm; }
-(BOOL)fileExistsAtPath:(NSString*)path { return [files containsObject:path]; }
-(BOOL)removeItemAtPath:(NSString*)path error:(NSError**)error {
    if([path isEqualToString:failRemove] || ![files containsObject:path])return NO;
    [files removeObject:path];return YES;
}
-(BOOL)moveItemAtPath:(NSString*)path toPath:(NSString*)target error:(NSError**)error {
    NSString* key=[NSString stringWithFormat:@"%@>%@",path,target];
    if([failMoves containsObject:key] || ![files containsObject:path] || [files containsObject:target])return NO;
    [files removeObject:path];[files addObject:target];return YES;
}
@end
static void reset(void) { files=[NSMutableSet setWithArray:@[@"inflight",@"patched",@"old"]];failMoves=[NSMutableSet new];failRemove=nil; }
'''
MAIN=r'''
int main(void) { @autoreleasepool {
    reset();assert(install_generated_dyld(@"inflight",@"patched",@"old",true)==0);
    assert([files containsObject:@"patched"] && [files containsObject:@"old"] && ![files containsObject:@"inflight"]);
    reset();failRemove=@"old";assert(install_generated_dyld(@"inflight",@"patched",@"old",true)==5);
    assert(files.count==3);
    reset();[failMoves addObject:@"patched>old"];assert(install_generated_dyld(@"inflight",@"patched",@"old",true)==6);
    assert([files containsObject:@"patched"] && [files containsObject:@"inflight"]);
    reset();[failMoves addObject:@"inflight>patched"];assert(install_generated_dyld(@"inflight",@"patched",@"old",true)==7);
    assert([files containsObject:@"patched"] && ![files containsObject:@"old"] && [files containsObject:@"inflight"]);
    reset();[failMoves addObject:@"inflight>patched"];[failMoves addObject:@"old>patched"];
    assert(install_generated_dyld(@"inflight",@"patched",@"old",true)==8);
    assert([files containsObject:@"old"] && [files containsObject:@"inflight"]);
    reset();[files removeObject:@"patched"];assert(install_generated_dyld(@"inflight",@"patched",@"old",false)==0);
    reset();assert(install_generated_dyld(@"inflight",@"patched",@"old",false)==7);
    assert([files containsObject:@"patched"]);
    puts("PASS: actual dyld install helper; remove/move failure, rollback, old vnode preserved");
} return 0; }
'''

def native_tests():
    clang=shutil.which('clang')
    if not clang:raise SystemExit('--native requires macOS clang/Foundation')
    body=extract(source(FILE),'static int install_generated_dyld').replace('NSFileManager','TestFileManager')
    with tempfile.TemporaryDirectory(prefix='rc9-dyld-') as temp:
        path=Path(temp)/'test.m';binary=Path(temp)/'test'
        path.write_text(PREFIX+body+MAIN,encoding='utf-8')
        subprocess.run([clang,'-fobjc-arc','-framework','Foundation','-Wall','-Wextra','-Werror',
            '-Wno-unused-parameter','-O1','-g','-fsanitize=address,undefined',str(path),'-o',str(binary)],check=True)
        subprocess.run([str(binary)],check=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--native',action='store_true')
    args=parser.parse_args()
    result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(DyldContracts))
    if not result.wasSuccessful():raise SystemExit(1)
    if args.native:native_tests()
    else:print('Source checks only; native checks require macOS Foundation.')
