int envbuf_len(const char *envp[]);
int envbuf_mutcopy(const char *envp[], char ***envpOut);
void envbuf_free(char *envp[]);
int envbuf_find(const char *envp[], const char *name);
const char *envbuf_getenv(const char *envp[], const char *name);
int envbuf_setenv(char **envpp[], const char *name, const char *value);
void envbuf_unsetenv(char **envpp[], const char *name);