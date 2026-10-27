"""Trustcache parser regressions with actual C bodies and injected I/O/allocation errors."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from test_rc9_services import extract, source

FILE='BaseBin/libjailbreak/src/trustcache.c'

class TrustcacheContracts(unittest.TestCase):
    def test_hash_batch_uses_checked_heap_allocation(self):
        body=extract(source(FILE),'int jb_trustcache_add_cdhashes')
        self.assertNotIn('entries[hashCount]',body)
        self.assertIn('calloc(hashCount',body)
        self.assertIn('free(entries)',body)
        self.assertIn('if (!hashes) return -1',body)

    def test_parser_validates_header_before_allocating_and_cleans_up(self):
        body=extract(source(FILE),'int trustcache_file_build_from_path')
        self.assertLess(body.index('header.length !='),body.index('malloc(tcSize)'))
        self.assertIn('header.version != 1',body)
        self.assertIn('*tcOut = NULL',body)
        self.assertIn('close(fd)',body)
        self.assertIn('free(file)',body)
        self.assertIn('trustcache_read_full(fd, file->entries',body)
        self.assertIn('errno == EINTR',extract(source(FILE),'static int trustcache_read_full'))

PREFIX=r'''
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <uuid/uuid.h>
#define CS_CDHASH_LEN 20
'''
MOCKS=r'''
static unsigned char input[256];
static size_t inputSize, position, maxRead;
static off_t reportedSize;
static int liveAllocations, openFiles, openError, statError, readError, interrupted, failAllocation, addCalls;
static mode_t fileMode;
static void* test_malloc(size_t size) { if(failAllocation)return NULL;void*p=malloc(size);if(p)liveAllocations++;return p; }
static void* test_calloc(size_t n,size_t s) { if(failAllocation)return NULL;void*p=calloc(n,s);if(p)liveAllocations++;return p; }
static void test_free(void* p) { if(p){liveAllocations--;free(p);} }
static int test_open(const char* path,int flags) { assert(path && (flags&O_CLOEXEC));if(openError)return -1;++openFiles;return 123; }
static int test_close(int fd) { assert(fd==123 && openFiles==1);--openFiles;return 0; }
static int test_fstat(int fd,struct stat* value) { assert(fd==123);if(statError)return -1;value->st_size=reportedSize;value->st_mode=fileMode;return 0; }
static ssize_t test_read(int fd,void* out,size_t n) {
    assert(fd==123);if(interrupted){interrupted=0;errno=EINTR;return -1;}
    if(readError){errno=EIO;return -1;}
    if(n>maxRead)n=maxRead;if(n>inputSize-position)n=inputSize-position;
    memcpy(out,input+position,n);position+=n;return n;
}
#define malloc test_malloc
#define calloc test_calloc
#define free test_free
#define open test_open
#define close test_close
#define fstat(...) test_fstat(__VA_ARGS__)
#define read test_read
static int jb_trustcache_add_entries(trustcache_entry_v1* entries,uint32_t count) {
    assert(entries && count==2);assert(entries[0].hash_type==1 && entries[1].hash_type==1);++addCalls;return 7;
}
static void reset(void) {
    assert(!liveAllocations && !openFiles);memset(input,0,sizeof(input));position=0;maxRead=256;
    openError=statError=readError=interrupted=failAllocation=addCalls=0;fileMode=S_IFREG;
    trustcache_file_v1* header=(trustcache_file_v1*)input;header->version=1;header->length=2;
    header->entries[0].hash[0]=2;header->entries[1].hash[0]=1;
    inputSize=reportedSize=sizeof(trustcache_file_v1)+2*sizeof(trustcache_entry_v1);
}
static void expect_failure(void) {
    trustcache_file_v1* result=(void*)1;
    assert(trustcache_file_build_from_path("fake",&result)==-1);
    assert(result==NULL && !liveAllocations && !openFiles);
}
'''
MAIN=r'''
int main(void) {
    trustcache_file_v1* result=NULL;
    reset();assert(trustcache_file_build_from_path(NULL,&result)==-1);
    assert(trustcache_file_build_from_path("fake",NULL)==-1);
    reset();openError=1;expect_failure();
    reset();statError=1;expect_failure();
    reset();fileMode=S_IFDIR;expect_failure();
    reset();reportedSize=-1;expect_failure();
    reset();reportedSize=sizeof(trustcache_file_v1)-1;expect_failure();
    reset();((trustcache_file_v1*)input)->version=2;expect_failure();
    reset();((trustcache_file_v1*)input)->length=UINT32_MAX;expect_failure();
    reset();reportedSize++;expect_failure();
    reset();inputSize=sizeof(trustcache_file_v1)-1;expect_failure();
    reset();inputSize--;expect_failure();
    reset();readError=1;expect_failure();
    reset();failAllocation=1;expect_failure();
    reset();maxRead=3;interrupted=1;
    assert(trustcache_file_build_from_path("fake",&result)==0 && result->length==2);
    assert(!openFiles && liveAllocations==1);free(result);
    reset();((trustcache_file_v1*)input)->length=0;reportedSize=inputSize=sizeof(trustcache_file_v1);
    assert(trustcache_file_build_from_path("fake",&result)==0 && result->length==0);free(result);
    cdhash_t hashes[2]={{2},{1}};
    reset();result=(void*)1;assert(trustcache_file_build_from_cdhashes(NULL,2,&result)==-1 && !result);
    assert(trustcache_file_build_from_cdhashes(hashes,0,&result)==-1 && !result);
    failAllocation=1;assert(trustcache_file_build_from_cdhashes(hashes,2,&result)==-1 && !result);
    failAllocation=0;assert(trustcache_file_build_from_cdhashes(hashes,2,&result)==0);
    assert(result->length==2 && result->entries[0].hash[0]==1 && result->entries[0].hash_type==2);free(result);
    reset();assert(jb_trustcache_add_cdhashes(NULL,0)==0);
    assert(jb_trustcache_add_cdhashes(NULL,2)==-1);
    failAllocation=1;assert(jb_trustcache_add_cdhashes(hashes,2)==-1 && !addCalls);
    failAllocation=0;assert(jb_trustcache_add_cdhashes(hashes,2)==7 && addCalls==1 && !liveAllocations);
    puts("PASS: actual trustcache parser/builders; short read, EINTR, malformed header, allocation and fd cleanup");
    return 0;
}
'''

def native_tests():
    compiler=shutil.which('clang')
    if not compiler:raise SystemExit('--native requires clang')
    structs=source('BaseBin/libjailbreak/src/trustcache_structs.h')
    structs=structs[structs.index('typedef uint8_t cdhash_t'):structs.index('#define JB_MAGIC')]
    text=source(FILE)
    functions='\n'.join(extract(text,a) for a in (
        'void _trustcache_file_init','int _trustcache_file_sort_entry_comparator_v1',
        'void _trustcache_file_sort(', 'int jb_trustcache_add_cdhashes',
        'int trustcache_file_build_from_cdhashes','static int trustcache_read_full','int trustcache_file_build_from_path'))
    declaration='int trustcache_file_build_from_path(const char*,trustcache_file_v1**);\n'
    program=PREFIX+structs+declaration+MOCKS+functions+MAIN
    with tempfile.TemporaryDirectory(prefix='rc9-trustcache-') as temp:
        path=Path(temp)/'test.c';binary=Path(temp)/'test'
        path.write_text(program,encoding='utf-8')
        subprocess.run([compiler,'-std=gnu11','-Wall','-Wextra','-Werror','-O1','-g',
            '-fsanitize=address,undefined',str(path),'-o',str(binary)],check=True)
        subprocess.run([str(binary)],check=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--native',action='store_true')
    args=parser.parse_args()
    result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(TrustcacheContracts))
    if not result.wasSuccessful():raise SystemExit(1)
    if args.native:native_tests()
    else:print('Source checks only; --native compiles and runs actual C with I/O fault injection.')
