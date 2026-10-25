#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>

int envbuf_len(const char *envp[])
{
	if (envp == NULL) return 1;

	int k = 0;
	const char *env = envp[k++];
	while (env != NULL) {
		env = envp[k++];
	}
	return k;
}

char **envbuf_mutcopy(const char *envp[])
{
	if (envp == NULL) return NULL;

	int len = envbuf_len(envp);
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

	return envcopy;
}

void envbuf_free(char *envp[])
{
	if (envp == NULL) return;

	int len = envbuf_len((const char**)envp);
	for (int i = 0; i < len-1; i++) {
		free(envp[i]);
	}
	free(envp);
}

int envbuf_find(const char *envp[], const char *name)
{
	if (envp) {
		unsigned long nameLen = strlen(name);
		int k = 0;
		const char *env = envp[k++];
		while (env != NULL) {
			unsigned long envLen = strlen(env);
			if (envLen > nameLen) {
				if (!strncmp(env, name, nameLen)) {
					if (env[nameLen] == '=') {
						return k-1;
					}
				}
			}
			env = envp[k++];
		}
	}
	return -1;
}

const char *envbuf_getenv(const char *envp[], const char *name)
{
	if (envp) {
		unsigned long nameLen = strlen(name);
		int envIndex = envbuf_find(envp, name);
		if (envIndex >= 0) {
			return &envp[envIndex][nameLen+1];
		}
	}
	return NULL;
}

bool envbuf_setenv(char **envpp[], const char *name, const char *value)
{
	if (!envpp || !name || !value) return false;

	char **envp = *envpp;
	bool newEnv = !envp;
	if (newEnv) {
		// Treat a missing environment as an empty, NULL-terminated buffer.
		envp = malloc(sizeof(char *));
		if (!envp) return false;
		envp[0] = NULL;
	}

	size_t nameLen = strlen(name);
	size_t valueLen = strlen(value);
	if (valueLen > SIZE_MAX - 2 || nameLen > SIZE_MAX - valueLen - 2) {
		if (newEnv) free(envp);
		return false;
	}
	char *envToSet = malloc(nameLen + valueLen + 2);
	if (!envToSet) {
		if (newEnv) free(envp);
		return false;
	}
	memcpy(envToSet, name, nameLen);
	envToSet[nameLen] = '=';
	memcpy(envToSet + nameLen + 1, value, valueLen + 1);

	int existingEnvIndex = envbuf_find((const char **)envp, name);
	if (existingEnvIndex >= 0) {
		// Replace only after the new value has been allocated.
		free(envp[existingEnvIndex]);
		envp[existingEnvIndex] = envToSet;
		return true;
	}

	int prevLen = envbuf_len((const char **)envp);
	char **newEnvp = realloc(envp, ((size_t)prevLen + 1) * sizeof(char *));
	if (!newEnvp) {
		free(envToSet);
		if (newEnv) free(envp);
		return false;
	}
	newEnvp[prevLen-1] = envToSet;
	newEnvp[prevLen] = NULL;
	*envpp = newEnvp;
	return true;
}

void envbuf_unsetenv(char **envpp[], const char *name)
{
	if (envpp) {
		char **envp = *envpp;
		if (!envp) return;

		int existingEnvIndex = envbuf_find((const char **)envp, name);
		if (existingEnvIndex >= 0) {
			free(envp[existingEnvIndex]);
			int prevLen = envbuf_len((const char **)envp);
			for (int i = existingEnvIndex; i < (prevLen-1); i++) {
				envp[i] = envp[i+1];
			}
			char **newEnvp = realloc(envp, (prevLen-1)*sizeof(const char *));
			if (newEnvp) *envpp = newEnvp;
		}
	}
}
