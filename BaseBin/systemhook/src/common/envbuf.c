#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#define ENVBUF_MAX_ENTRIES 4096

int envbuf_len(const char *envp[])
{
	if (envp == NULL) return 1;

	for (int k = 0; k < ENVBUF_MAX_ENTRIES; k++) {
		if (envp[k] == NULL) return k + 1;
	}
	return -1;
}

char **envbuf_mutcopy(const char *envp[])
{
	if (envp == NULL) return calloc(1, sizeof(char *));

	int len = envbuf_len(envp);
	if (len < 1 || (size_t)len > SIZE_MAX / sizeof(char *)) return NULL;
	char **envcopy = calloc((size_t)len, sizeof(char *));
	if (!envcopy) return NULL;

	for (int i = 0; i < len-1; i++) {
		envcopy[i] = strdup(envp[i]);
		if (!envcopy[i]) {
			for (int j = 0; j < i; j++) free(envcopy[j]);
			free(envcopy);
			return NULL;
		}
	}
	envcopy[len-1] = NULL;

	return envcopy;
}

void envbuf_free(char *envp[])
{
	if (envp == NULL) return;

	int len = envbuf_len((const char**)envp);
	if (len < 1) return;
	for (int i = 0; i < len-1; i++) {
		free(envp[i]);
	}
	free(envp);
}

int envbuf_find(const char *envp[], const char *name)
{
	if (envp && name) {
		unsigned long nameLen = strlen(name);
		for (int k = 0; k < ENVBUF_MAX_ENTRIES && envp[k] != NULL; k++) {
			const char *env = envp[k];
			unsigned long envLen = strlen(env);
			if (envLen > nameLen) {
				if (!strncmp(env, name, nameLen)) {
					if (env[nameLen] == '=') {
						return k;
					}
				}
			}
		}
	}
	return -1;
}

const char *envbuf_getenv(const char *envp[], const char *name)
{
	if (envp && name) {
		unsigned long nameLen = strlen(name);
		int envIndex = envbuf_find(envp, name);
		if (envIndex >= 0) {
			return &envp[envIndex][nameLen+1];
		}
	}
	return NULL;
}

void envbuf_setenv(char **envpp[], const char *name, const char *value)
{
	if (envpp && name && value && name[0] != '\0' && !strchr(name, '=')) {
		char **envp = *envpp;
		if (!envp) {
			// treat NULL as [NULL]
			envp = malloc(sizeof(const char *));
			if (!envp) return;
			envp[0] = NULL;
		}

		size_t nameLength = strlen(name);
		size_t valueLength = strlen(value);
		if (valueLength > SIZE_MAX - 2 || nameLength > SIZE_MAX - valueLength - 2) {
			if (!*envpp) free(envp);
			return;
		}
		char *envToSet = malloc(nameLength + valueLength + 2);
		if (!envToSet) {
			if (!*envpp) free(envp);
			return;
		}
		strcpy(envToSet, name);
		strcat(envToSet, "=");
		strcat(envToSet, value);

		int existingEnvIndex = envbuf_find((const char **)envp, name);
		if (existingEnvIndex >= 0) {
			// if already exists: deallocate old variable, then replace pointer
			free(envp[existingEnvIndex]);
			envp[existingEnvIndex] = envToSet;
		}
		else {
			// if doesn't exist yet: increase env buffer size, place at end
			int prevLen = envbuf_len((const char **)envp);
			if (prevLen < 1 || prevLen >= ENVBUF_MAX_ENTRIES) {
				free(envToSet);
				if (!*envpp) free(envp);
				return;
			}
			char **newEnvp = realloc(envp, (prevLen+1)*sizeof(const char *));
			if (!newEnvp) {
				free(envToSet);
				if (!*envpp) free(envp);
				return;
			}
			*envpp = newEnvp;
			envp = newEnvp;
			envp[prevLen-1] = envToSet;
			envp[prevLen] = NULL;
		}
	}
}

void envbuf_unsetenv(char **envpp[], const char *name)
{
	if (envpp && name) {
		char **envp = *envpp;
		if (!envp) return;

		int existingEnvIndex = envbuf_find((const char **)envp, name);
		if (existingEnvIndex >= 0) {
			int prevLen = envbuf_len((const char **)envp);
			if (prevLen < 1) return;
			free(envp[existingEnvIndex]);
			for (int i = existingEnvIndex; i < (prevLen-1); i++) {
				envp[i] = envp[i+1];
			}
			char **newEnvp = realloc(envp, (prevLen-1)*sizeof(const char *));
			if (newEnvp) *envpp = newEnvp;
		}
	}
}
