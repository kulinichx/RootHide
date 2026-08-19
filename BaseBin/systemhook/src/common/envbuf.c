#include <errno.h>
#include <stdlib.h>
#include <string.h>

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

int envbuf_mutcopy(const char *envp[], char ***envpOut)
{
	if (!envpOut) {
		return EINVAL;
	}

	*envpOut = NULL;

	/*
	 * Preserve the original NULL-environment behavior.
	 * NULL is a valid successful result when the input envp is NULL;
	 * allocation failure is reported separately via the return value.
	 */
	if (envp == NULL) {
		return 0;
	}

	int len = envbuf_len(envp);
	char **envcopy = malloc((size_t)len * sizeof(char *));

	if (!envcopy) {
		return ENOMEM;
	}

	for (int i = 0; i < len - 1; i++) {
		envcopy[i] = strdup(envp[i]);

		if (!envcopy[i]) {
			for (int j = 0; j < i; j++) {
				free(envcopy[j]);
			}

			free(envcopy);
			return ENOMEM;
		}
	}

	envcopy[len - 1] = NULL;
	*envpOut = envcopy;

	return 0;
}

void envbuf_free(char *envp[])
{
	if (envp == NULL) return;

	int len = envbuf_len((const char **)envp);
	for (int i = 0; i < len - 1; i++) {
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
						return k - 1;
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
			return &envp[envIndex][nameLen + 1];
		}
	}

	return NULL;
}

int envbuf_setenv(char **envpp[], const char *name, const char *value)
{
	if (!envpp || !name || !value) {
		return EINVAL;
	}

	char **envp = *envpp;

	char *envToSet = malloc(strlen(name) + strlen(value) + 2);
	if (!envToSet) {
		return ENOMEM;
	}

	strcpy(envToSet, name);
	strcat(envToSet, "=");
	strcat(envToSet, value);

	int existingEnvIndex = envbuf_find((const char **)envp, name);

	if (existingEnvIndex >= 0) {
		/*
		 * Allocate the replacement before touching the old entry,
		 * so allocation failure never damages the existing env.
		 */
		free(envp[existingEnvIndex]);
		envp[existingEnvIndex] = envToSet;
		return 0;
	}

	int prevLen = envbuf_len((const char **)envp);

	/*
	 * Never overwrite the original pointer until realloc succeeds.
	 */
	char **newEnvp = realloc(
		envp,
		(size_t)(prevLen + 1) * sizeof(char *)
	);

	if (!newEnvp) {
		free(envToSet);
		return ENOMEM;
	}

	newEnvp[prevLen - 1] = envToSet;
	newEnvp[prevLen] = NULL;

	*envpp = newEnvp;

	return 0;
}

void envbuf_unsetenv(char **envpp[], const char *name)
{
	if (!envpp) return;

	char **envp = *envpp;
	if (!envp) return;

	int existingEnvIndex =
		envbuf_find((const char **)envp, name);

	if (existingEnvIndex < 0) return;

	int prevLen = envbuf_len((const char **)envp);

	free(envp[existingEnvIndex]);

	for (int i = existingEnvIndex; i < prevLen - 1; i++) {
		envp[i] = envp[i + 1];
	}

	/*
	 * Shrinking is optional.
	 * If realloc fails, the old allocation is still valid and
	 * already contains the correct NULL-terminated environment.
	 */
	char **newEnvp = realloc(
		envp,
		(size_t)(prevLen - 1) * sizeof(char *)
	);

	if (newEnvp) {
		*envpp = newEnvp;
	}
}
