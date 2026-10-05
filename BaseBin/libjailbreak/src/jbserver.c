#include "jbserver.h"
#include "util.h"

#include "roothider.h"

static bool jbserver_xpc_value_matches_type(xpc_object_t value, jbserver_type type)
{
	if (!value) return true; // Individual handlers retain their existing optional-argument semantics.

	xpc_type_t actualType = xpc_get_type(value);
	switch (type) {
		case JBS_TYPE_BOOL:       return actualType == XPC_TYPE_BOOL;
		case JBS_TYPE_UINT64:     return actualType == XPC_TYPE_UINT64;
		case JBS_TYPE_STRING:     return actualType == XPC_TYPE_STRING;
		case JBS_TYPE_DATA:       return actualType == XPC_TYPE_DATA;
		case JBS_TYPE_ARRAY:      return actualType == XPC_TYPE_ARRAY;
		case JBS_TYPE_DICTIONARY: return actualType == XPC_TYPE_DICTIONARY;
		case JBS_TYPE_FD:         return actualType == XPC_TYPE_FD;
		case JBS_TYPE_XPC_GENERIC:
		case JBS_TYPE_CALLER_TOKEN:
			return true;
	}

	return false;
}

int jbserver_received_xpc_message(struct jbserver_impl *server, xpc_object_t xmsg)
{
	if (!server || !server->domains || !xmsg || xpc_get_type(xmsg) != XPC_TYPE_DICTIONARY) return -1;

/**********************************************/
	roothide_handle_xpc_msg(xmsg);
/*********************************************/

	xpc_object_t domainValue = xpc_dictionary_get_value(xmsg, "jb-domain");
	xpc_object_t actionValue = xpc_dictionary_get_value(xmsg, "action");
	if (!domainValue || xpc_get_type(domainValue) != XPC_TYPE_UINT64) return -1;
	if (!actionValue || xpc_get_type(actionValue) != XPC_TYPE_UINT64) return -1;

	uint64_t domainIdx = xpc_dictionary_get_uint64(xmsg, "jb-domain");
	if (domainIdx == 0 || domainIdx > server->maxDomain) return -1;
	struct jbserver_domain *domain = server->domains[domainIdx - 1];
	if (!domain) return -1;

	audit_token_t clientToken = { 0 };
	xpc_dictionary_get_audit_token(xmsg, &clientToken);

	if (domain->permissionHandler) {
		if (!domain->permissionHandler(clientToken)) return -2;
	}

	uint64_t actionIdx = xpc_dictionary_get_uint64(xmsg, "action");
	if (actionIdx == 0) return -1;
	struct jbserver_action *action = &domain->actions[0];
	for (uint64_t i = 1; i < actionIdx && action->handler; i++) {
		action = &domain->actions[i];
	}
	if (!action->handler) return -1;

	int (*handler)(void *a1, void *a2, void *a3, void *a4, void *a5, void *a6, void *a7, void *a8) = action->handler;
	void *args[8] = { NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL };
	void *argsOut[8] = { NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL };

	for (uint64_t i = 0; i < 8 && action->args[i].name; i++) {
		jbserver_arg *argDesc = &action->args[i];
		if (argDesc->out || argDesc->type == JBS_TYPE_CALLER_TOKEN) continue;

		xpc_object_t value = xpc_dictionary_get_value(xmsg, argDesc->name);
		if (!jbserver_xpc_value_matches_type(value, argDesc->type)) return -3;
	}

	for (uint64_t i = 0; i < 8 && action->args[i].name; i++) {
		jbserver_arg *argDesc = &action->args[i];
		if (!argDesc->out) {
			switch (argDesc->type) {
				case JBS_TYPE_BOOL:
				args[i] = (void *)xpc_dictionary_get_bool(xmsg, argDesc->name);
				break;
				case JBS_TYPE_UINT64:
				args[i] = (void *)xpc_dictionary_get_uint64(xmsg, argDesc->name);
				break;
				case JBS_TYPE_FD:
				args[i] = (void *)(int64_t)xpc_dictionary_dup_fd(xmsg, argDesc->name);
				break;
				case JBS_TYPE_STRING:
				args[i] = (void *)xpc_dictionary_get_string(xmsg, argDesc->name);
				break;
				case JBS_TYPE_DATA: { // Data occupies 2 arguments (buf, len)
					if (i < 7) {
						args[i] = (void *)xpc_dictionary_get_data(xmsg, argDesc->name, (size_t *)&args[i+1]); i++;
					}
					break;
				}
				case JBS_TYPE_ARRAY:
				args[i] = (void *)xpc_dictionary_get_array(xmsg, argDesc->name);
				break;
				case JBS_TYPE_DICTIONARY:
				args[i] = (void *)xpc_dictionary_get_dictionary(xmsg, argDesc->name);
				break;
				case JBS_TYPE_XPC_GENERIC:
				args[i] = (void *)xpc_dictionary_get_value(xmsg, argDesc->name);
				break;
				case JBS_TYPE_CALLER_TOKEN:
				args[i] = (void *)&clientToken;
				break;
			}
		}
		else {
			args[i] = &argsOut[i];
		}
	}

	xpc_object_t xreply = xpc_dictionary_create_reply(xmsg);
	if (!xreply) {
		for (uint64_t i = 0; i < 8 && action->args[i].name; i++) {
			jbserver_arg *argDesc = &action->args[i];
			if (!argDesc->out && argDesc->type == JBS_TYPE_FD && (int)(int64_t)args[i] >= 0) {
				close((int)(int64_t)args[i]);
			}
		}
		return -4;
	}

	int result = handler(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7]);

	for (uint64_t i = 0; i < 8 && action->args[i].name; i++) {
		jbserver_arg *argDesc = &action->args[i];
		if (argDesc->out) {
			switch (argDesc->type) {
				case JBS_TYPE_BOOL:
				xpc_dictionary_set_bool(xreply, argDesc->name, (bool)argsOut[i]);
				break;
				case JBS_TYPE_UINT64:
				xpc_dictionary_set_uint64(xreply, argDesc->name, (uint64_t)argsOut[i]);
				break;
				case JBS_TYPE_FD: {
					xpc_dictionary_set_fd(xreply, argDesc->name, (int)(int64_t)argsOut[i]);
					close((int)(int64_t)argsOut[i]);
					break;
				}
				case JBS_TYPE_STRING: {
					if (argsOut[i]) {
						xpc_dictionary_set_string(xreply, argDesc->name, (char *)argsOut[i]);
						free(argsOut[i]);
					}
					break;
				}
				case JBS_TYPE_DATA: {
					if (i < 7) {
						if (argsOut[i] && action->args[i+1].name) {
							xpc_dictionary_set_data(xreply, argDesc->name, (const void *)argsOut[i], (size_t)argsOut[i+1]);
							free(argsOut[i]);
						}
					}
					break;
				}
				case JBS_TYPE_ARRAY:
				case JBS_TYPE_DICTIONARY:
				case JBS_TYPE_XPC_GENERIC: {
					if (argsOut[i]) {
						xpc_dictionary_set_value(xreply, argDesc->name, (xpc_object_t)argsOut[i]);
						xpc_release((xpc_object_t)argsOut[i]);
					}
					break;
				}
				default:
				break;
			}
		}
		else {
			if (argDesc->type == JBS_TYPE_FD) {
				close((int)(int64_t)args[i]);
			}
		}
	}
	xpc_dictionary_set_int64(xreply, "result", result);
	xpc_pipe_routine_reply(xreply);
	xpc_release(xreply);

	return 0;
}
