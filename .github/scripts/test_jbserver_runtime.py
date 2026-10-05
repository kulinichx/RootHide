#!/usr/bin/env python3
from pathlib import Path
import subprocess, tempfile
ROOT=Path(__file__).resolve().parents[2]
source=(ROOT/'BaseBin/libjailbreak/src/jbserver.c').read_text()
def extract(sig):
 s=source.index(sig); b=source.index('{',s); d=0
 for i in range(b,len(source)):
  if source[i]=='{': d+=1
  elif source[i]=='}':
   d-=1
   if d==0:return source[s:i+1]
 raise RuntimeError(sig)
match=extract('static bool jbserver_xpc_value_matches_type')
recv=extract('int jbserver_received_xpc_message')
h=r'''#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
typedef struct { uint32_t v[8]; } audit_token_t;
typedef enum { JBS_TYPE_BOOL,JBS_TYPE_UINT64,JBS_TYPE_STRING,JBS_TYPE_DATA,JBS_TYPE_ARRAY,JBS_TYPE_DICTIONARY,JBS_TYPE_FD,JBS_TYPE_CALLER_TOKEN,JBS_TYPE_XPC_GENERIC } jbserver_type;
typedef struct { const char *name; jbserver_type type; bool out; } jbserver_arg;
struct jbserver_action { void *handler; jbserver_arg *args; };
struct jbserver_domain { bool (*permissionHandler)(audit_token_t); struct jbserver_action actions[2]; };
struct jbserver_impl { uint64_t maxDomain; struct jbserver_domain **domains; };
typedef enum { T_DICT,T_UINT,T_BOOL,T_DATA,T_STRING,T_ARRAY,T_FD,T_GENERIC } fake_type;
typedef struct fake { fake_type type; uint64_t domain,action,fd; bool attach; const void *data; size_t len; } *xpc_object_t;
typedef fake_type xpc_type_t;
#define XPC_TYPE_DICTIONARY T_DICT
#define XPC_TYPE_UINT64 T_UINT
#define XPC_TYPE_BOOL T_BOOL
#define XPC_TYPE_DATA T_DATA
#define XPC_TYPE_STRING T_STRING
#define XPC_TYPE_ARRAY T_ARRAY
#define XPC_TYPE_FD T_FD
static struct fake type_uint={T_UINT},type_bool={T_BOOL},type_data={T_DATA};
static xpc_type_t xpc_get_type(xpc_object_t o){ return o?o->type:T_OTHER; }
static xpc_object_t xpc_dictionary_get_value(xpc_object_t o,const char*n){ if(!o)return 0; if(!strcmp(n,"jb-domain"))return o->domain?&type_uint:0; if(!strcmp(n,"action"))return o->action?&type_uint:0; if(!strcmp(n,"fd"))return &type_uint; if(!strcmp(n,"blob"))return o->data?&type_data:0; if(!strcmp(n,"blob-length"))return 0; if(!strcmp(n,"attach"))return &type_bool; return 0; }
static uint64_t xpc_dictionary_get_uint64(xpc_object_t o,const char*n){ if(!strcmp(n,"jb-domain"))return o->domain;if(!strcmp(n,"action"))return o->action;if(!strcmp(n,"fd"))return o->fd;return 0; }
static bool xpc_dictionary_get_bool(xpc_object_t o,const char*n){(void)n;return o->attach;}
static const void*xpc_dictionary_get_data(xpc_object_t o,const char*n,size_t*l){(void)n;*l=o->len;return o->data;}
static const char*xpc_dictionary_get_string(xpc_object_t o,const char*n){(void)o;(void)n;return 0;}
static xpc_object_t xpc_dictionary_get_array(xpc_object_t o,const char*n){(void)o;(void)n;return 0;}
static xpc_object_t xpc_dictionary_get_dictionary(xpc_object_t o,const char*n){(void)o;(void)n;return 0;}
static int xpc_dictionary_dup_fd(xpc_object_t o,const char*n){(void)o;(void)n;return -1;}
static void xpc_dictionary_get_audit_token(xpc_object_t o,audit_token_t*t){(void)o;memset(t,0,sizeof(*t));}
static struct fake reply={T_DICT};
static xpc_object_t xpc_dictionary_create_reply(xpc_object_t o){return o?&reply:0;}
static void xpc_dictionary_set_bool(xpc_object_t o,const char*n,bool v){(void)o;(void)n;(void)v;}
static void xpc_dictionary_set_uint64(xpc_object_t o,const char*n,uint64_t v){(void)o;(void)n;(void)v;}
static void xpc_dictionary_set_int64(xpc_object_t o,const char*n,int64_t v){(void)o;(void)n;(void)v;}
static void xpc_dictionary_set_fd(xpc_object_t o,const char*n,int v){(void)o;(void)n;(void)v;}
static void xpc_dictionary_set_string(xpc_object_t o,const char*n,const char*v){(void)o;(void)n;(void)v;}
static void xpc_dictionary_set_data(xpc_object_t o,const char*n,const void*v,size_t l){(void)o;(void)n;(void)v;(void)l;}
static void xpc_dictionary_set_value(xpc_object_t o,const char*n,xpc_object_t v){(void)o;(void)n;(void)v;}
static void xpc_pipe_routine_reply(xpc_object_t o){(void)o;}
static void xpc_release(xpc_object_t o){(void)o;}
static void roothide_handle_xpc_msg(xpc_object_t o){(void)o;}
static int called; static int handler(void*t,void*fd,void*d,void*l,void*a,void*x,void*y,void*z){(void)t;(void)x;(void)y;(void)z;called++;assert((uint64_t)fd==9);assert(d!=0);assert((size_t)l==4);assert((bool)a);return 0;}
'''
main=r'''int main(void){
 jbserver_arg args[]={{"caller",JBS_TYPE_CALLER_TOKEN,0},{"fd",JBS_TYPE_UINT64,0},{"blob",JBS_TYPE_DATA,0},{"blob-length",JBS_TYPE_UINT64,0},{"attach",JBS_TYPE_BOOL,0},{0}};
 struct jbserver_domain domain={0}; domain.actions[0]=(struct jbserver_action){handler,args}; struct jbserver_domain*domains[]={&domain}; struct jbserver_impl server={1,domains};
 char bytes[4]={0}; struct fake msg={T_DICT,1,1,9,1,bytes,sizeof(bytes)};
 assert(jbserver_received_xpc_message(0,&msg)==-1); assert(jbserver_received_xpc_message(&server,0)==-1);
 msg.domain=2; assert(jbserver_received_xpc_message(&server,&msg)==-1); msg.domain=1;
 msg.action=0; assert(jbserver_received_xpc_message(&server,&msg)==-1); msg.action=1;
 assert(jbserver_received_xpc_message(&server,&msg)==0); assert(called==1); return 0; }
'''
with tempfile.TemporaryDirectory() as d:
 c=Path(d)/'t.c'; exe=Path(d)/'t'; c.write_text(h+'\n'+match+'\n'+recv+'\n'+main)
 subprocess.run(['xcrun','clang','-std=c11','-Wall','-Wextra','-Werror','-fsanitize=address,undefined',str(c),'-o',str(exe)],check=True)
 subprocess.run([str(exe)],check=True)
print('PASS: jbserver malformed dispatch and DATA ABI runtime')
