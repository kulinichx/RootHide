#!/usr/bin/env python3
"""Extract actual C getters and test protocol/ownership with a bounded XPC model.
Not a real-libxpc, Objective-C ARC, iOS build, or device test.
Run: python3 test_jbsettings_reply.py --source path/to/jbclient_xpc.c
Optional: CC=gcc SANITIZERS=address,undefined (default undefined).
"""
from pathlib import Path
import argparse, os, shlex, subprocess, tempfile
p = argparse.ArgumentParser()
p.add_argument('--source', type=Path, default=Path(__file__).resolve().parents[2] / 'BaseBin/libjailbreak/src/jbclient_xpc.c')
a = p.parse_args()
source = a.source.read_text(encoding='utf-8')
def extract(signature):
    start = source.index(signature)
    begin = source.index('{', start)
    depth = 0
    for end in range(begin, len(source)):
        if source[end] == '{': depth += 1
        elif source[end] == '}':
            depth -= 1
            if depth == 0: return source[start:end+1]
    raise ValueError(signature)
functions = '\n'.join(extract(sig) for sig in [
    'int jbclient_jbsettings_get(', 'bool jbclient_jbsettings_get_bool(',
    'uint64_t jbclient_jbsettings_get_uint64(', 'double jbclient_jbsettings_get_double('])
model = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
enum { XPC_TYPE_DICTIONARY=1, XPC_TYPE_INT64, XPC_TYPE_BOOL, XPC_TYPE_UINT64, XPC_TYPE_DOUBLE, TYPE_STRING };
typedef struct obj { int type, refs; int64_t i; uint64_t u; double d; bool b; struct obj *result, *value; } *xpc_object_t;
static int live, copies, sends, cases;
static bool fail_args, fail_copy;
static xpc_object_t next_reply;
#define JBS_DOMAIN_SYSTEMWIDE 1
#define JBS_SYSTEMWIDE_JBSETTINGS_GET 7
static xpc_object_t make(int type) {
    xpc_object_t o=calloc(1,sizeof(*o)); assert(o); o->type=type; o->refs=1; live++; return o;
}
static int xpc_get_type(xpc_object_t o) { assert(o && o->refs>0); return o->type; }
static void xpc_release(xpc_object_t o) {
    assert(o && o->refs>0);
    if (--o->refs==0) {
        if(o->result) xpc_release(o->result);
        if(o->value) xpc_release(o->value);
        live--; free(o);
    }
}
static xpc_object_t xpc_dictionary_create_empty(void) { return fail_args ? NULL : make(XPC_TYPE_DICTIONARY); }
static void xpc_dictionary_set_string(xpc_object_t o,const char *k,const char *v) {
    assert(xpc_get_type(o)==XPC_TYPE_DICTIONARY && !strcmp(k,"key") && v);
}
static xpc_object_t xpc_dictionary_get_value(xpc_object_t o,const char *k) {
    assert(xpc_get_type(o)==XPC_TYPE_DICTIONARY);
    if(!strcmp(k,"result")) return o->result;
    if(!strcmp(k,"value")) return o->value;
    abort();
}
static int64_t xpc_dictionary_get_int64(xpc_object_t o,const char *k) {
    xpc_object_t v=xpc_dictionary_get_value(o,k);
    return v && v->type==XPC_TYPE_INT64 ? v->i : 0;
}
static xpc_object_t xpc_copy(xpc_object_t v) {
    copies++; if(fail_copy) return NULL;
    assert(v && !v->result && !v->value);
    xpc_object_t o=make(v->type); o->i=v->i; o->u=v->u; o->d=v->d; o->b=v->b; return o;
}
static bool xpc_bool_get_value(xpc_object_t v) { assert(xpc_get_type(v)==XPC_TYPE_BOOL); return v->b; }
static uint64_t xpc_uint64_get_value(xpc_object_t v) { assert(xpc_get_type(v)==XPC_TYPE_UINT64); return v->u; }
static double xpc_double_get_value(xpc_object_t v) { assert(xpc_get_type(v)==XPC_TYPE_DOUBLE); return v->d; }
static xpc_object_t jbserver_xpc_send(int domain,int action,xpc_object_t args) {
    assert(domain==1 && action==7 && args); sends++;
    xpc_object_t r=next_reply; next_reply=NULL; return r;
}
/* Test setup transfers owning references to the reply container. */
static void reply(int result_type,int64_t result,int value_type) {
    assert(!next_reply);
    next_reply=make(XPC_TYPE_DICTIONARY);
    if(result_type) { next_reply->result=make(result_type); next_reply->result->i=result; }
    if(value_type) {
        next_reply->value=make(value_type);
        next_reply->value->b=true; next_reply->value->u=UINT64_MAX;
        next_reply->value->d=2.75;
    }
}
static void done(void) { assert(!next_reply && live==0); fail_copy=fail_args=false; cases++; }
'''
tests = r'''
static void failure(int expected) {
    xpc_object_t sentinel=make(TYPE_STRING), out=sentinel;
    int before=copies;
    assert(jbclient_jbsettings_get("key",&out)==expected);
    assert(out==sentinel); assert(copies==before || fail_copy);
    xpc_release(sentinel); done();
}
int main(void) {
    reply(XPC_TYPE_INT64,0,XPC_TYPE_BOOL); assert(jbclient_jbsettings_get_bool("x")); done();
    reply(XPC_TYPE_INT64,0,XPC_TYPE_UINT64); assert(jbclient_jbsettings_get_uint64("x")==UINT64_MAX); done();
    reply(XPC_TYPE_INT64,0,XPC_TYPE_DOUBLE); assert(jbclient_jbsettings_get_double("x")==2.75); done();
    reply(XPC_TYPE_INT64,0,TYPE_STRING); assert(!jbclient_jbsettings_get_bool("x")); done();
    reply(XPC_TYPE_INT64,0,TYPE_STRING); assert(!jbclient_jbsettings_get_uint64("x")); done();
    reply(XPC_TYPE_INT64,0,XPC_TYPE_UINT64); assert(!jbclient_jbsettings_get_double("x")); done();
    failure(-1); /* transport returns NULL */
    next_reply=make(TYPE_STRING); failure(-1);
    reply(0,0,XPC_TYPE_BOOL); failure(-1);
    reply(XPC_TYPE_UINT64,0,XPC_TYPE_BOOL); failure(-1);
    reply(XPC_TYPE_INT64,-17,XPC_TYPE_BOOL); failure(-17);
    reply(XPC_TYPE_INT64,7,0); failure(7);
    reply(XPC_TYPE_INT64,INT_MIN,0); failure(INT_MIN);
    reply(XPC_TYPE_INT64,INT_MAX,0); failure(INT_MAX);
    reply(XPC_TYPE_INT64,(int64_t)INT_MAX+1,XPC_TYPE_BOOL); failure(-1);
    reply(XPC_TYPE_INT64,(int64_t)INT_MIN-1,XPC_TYPE_BOOL); failure(-1);
    reply(XPC_TYPE_INT64,INT64_C(4294967296),XPC_TYPE_BOOL); failure(-1);
    reply(XPC_TYPE_INT64,0,0); failure(-1);
    reply(XPC_TYPE_INT64,0,XPC_TYPE_BOOL); fail_copy=true; failure(-1);
    fail_args=true; failure(-1);
    int old_sends=sends;
    xpc_object_t out=NULL; assert(jbclient_jbsettings_get(NULL,&out)==-1 && !out && sends==old_sends); done();
    reply(XPC_TYPE_INT64,0,XPC_TYPE_BOOL); int old_copies=copies;
    assert(jbclient_jbsettings_get("x",NULL)==0 && copies==old_copies); done();
    reply(XPC_TYPE_INT64,0,0); assert(jbclient_jbsettings_get("x",NULL)==-1); done();
    reply(XPC_TYPE_INT64,0,XPC_TYPE_DOUBLE);
    assert(jbclient_jbsettings_get("x",&out)==0 && out && out->d==2.75 && live==1);
    xpc_release(out); out=NULL; done();
    reply(XPC_TYPE_INT64,0,0); assert(jbclient_jbsettings_get_double("x")==0); done();
    reply(0,0,XPC_TYPE_BOOL); assert(!jbclient_jbsettings_get_bool("x")); done();
    for(int n=0;n<100;n++) {
        reply(XPC_TYPE_INT64,0,XPC_TYPE_DOUBLE); assert(jbclient_jbsettings_get_double("x")==2.75); done();
        reply(XPC_TYPE_INT64,-1,0); assert(jbclient_jbsettings_get_double("x")==0); done();
        reply(XPC_TYPE_INT64,0,0); assert(jbclient_jbsettings_get_double("x")==0); done();
    }
    printf("PASS: %d cases including 100 success/error/malformed cycles; live=%d\n",cases,live);
    return 0;
}
'''
with tempfile.TemporaryDirectory() as d:
    c=Path(d)/'test.c'; exe=Path(d)/'test'
    c.write_text(model+'\n'+functions+'\n'+tests,encoding='utf-8')
    cc=shlex.split(os.environ.get('CC','cc'))
    flags=['-std=c11','-Wall','-Wextra','-Werror','-g','-O1']
    sanitizers=os.environ.get('SANITIZERS','undefined')
    if sanitizers: flags += ['-fsanitize='+sanitizers,'-fno-omit-frame-pointer']
    cmd=cc+flags+[str(c),'-o',str(exe)]
    print('Compiler:',subprocess.check_output(cc+['--version'],text=True).splitlines()[0],flush=True)
    print('Flags:', ' '.join(flags),flush=True)
    subprocess.run(cmd,check=True)
    subprocess.run([str(exe)],check=True)
