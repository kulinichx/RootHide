#include <libjailbreak/jbserver.h>

extern struct jbserver_domain gSystemwideDomain;
extern struct jbserver_domain gPlatformDomain;
extern struct jbserver_domain gWatchdogDomain;
extern struct jbserver_domain gRootDomain;
extern struct jbserver_domain gDopamineDomain;
extern struct jbserver_domain gRootHideDomain;

static struct jbserver_domain *gGlobalDomains[] = {
		&gSystemwideDomain,
		&gPlatformDomain,
		&gWatchdogDomain,
		&gRootDomain,
		&gDopamineDomain,
		&gRootHideDomain,
		NULL,
};

struct jbserver_impl gGlobalServer = {
	.maxDomain = (sizeof(gGlobalDomains) / sizeof(gGlobalDomains[0])) - 1,
	.domains = gGlobalDomains,
};