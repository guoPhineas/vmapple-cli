#include "ticket.h"

#if defined(__linux__) || defined(__APPLE__)

#include <libtatsu/tss.h>
#include <plist/plist.h>
#include <stdlib.h>
#include <string.h>

static plist_t erase_identity(plist_t manifest) {
    plist_t identities = plist_dict_get_item(manifest, "BuildIdentities");
    for (uint32_t index = 0; index < plist_array_get_size(identities); index++) {
        plist_t identity = plist_array_get_item(identities, index);
        plist_t info = plist_dict_get_item(identity, "Info");
        const char *device = plist_get_string_ptr(plist_dict_get_item(info, "DeviceClass"), NULL);
        const char *variant = plist_get_string_ptr(plist_dict_get_item(info, "Variant"), NULL);
        const char *behavior = plist_get_string_ptr(plist_dict_get_item(info, "RestoreBehavior"), NULL);
        if (device && variant && behavior &&
            strcasecmp(device, "vma2macosap") == 0 &&
            strstr(variant, "Erase Install") != NULL &&
            strcmp(behavior, "Erase") == 0) {
            return identity;
        }
    }
    return NULL;
}

int vmapple_ticket_request(
    const void *manifest,
    size_t manifest_size,
    uint64_t ecid,
    const uint8_t ap_nonce[32],
    const uint8_t sep_nonce[20],
    const uint8_t *policy_digest,
    const uint8_t *next_stage_hash,
    uint8_t **ticket,
    size_t *ticket_size
) {
    plist_t root = NULL;
    plist_from_memory(manifest, (uint32_t)manifest_size, &root, NULL);
    plist_t identity = root ? erase_identity(root) : NULL;
    if (identity == NULL) {
        plist_free(root);
        return -1;
    }

    plist_t parameters = plist_new_dict();
    plist_dict_set_item(parameters, "ApECID", plist_new_uint(ecid));
    plist_dict_set_item(parameters, "ApNonce", plist_new_data((const char *)ap_nonce, 32));
    plist_dict_set_item(parameters, "ApSepNonce", plist_new_data((const char *)sep_nonce, 20));
    plist_dict_set_item(parameters, "ApProductionMode", plist_new_bool(1));
    plist_dict_set_item(parameters, "ApSecurityMode", plist_new_bool(1));
    plist_dict_set_item(parameters, "ApSupportsImg4", plist_new_bool(1));
    tss_parameters_add_from_manifest(parameters, identity, true);

    plist_t request = tss_request_new(NULL);
    int failed;
    if (policy_digest != NULL) {
        plist_t policy = plist_new_dict();
        plist_dict_set_item(policy, "Digest", plist_new_data((const char *)policy_digest, 48));
        plist_dict_set_item(policy, "Trusted", plist_new_bool(1));
        plist_dict_set_item(parameters, "Ap,LocalPolicy", policy);
        plist_dict_set_item(parameters, "Ap,LocalBoot", plist_new_bool(0));
        plist_dict_set_item(
            parameters,
            "Ap,NextStageIM4MHash",
            plist_new_data((const char *)next_stage_hash, 48)
        );
        failed = tss_request_add_local_policy_tags(request, parameters);
    } else {
        failed = tss_request_add_common_tags(request, parameters, NULL) ||
            tss_request_add_ap_tags(request, parameters, NULL) ||
            tss_request_add_ap_img4_tags(request, parameters);
    }

    int result = -2;
    plist_t response = failed ? NULL : tss_request_send(request, NULL);
    plist_t data = response ? plist_dict_get_item(response, "ApImg4Ticket") : NULL;
    if (data != NULL) {
        uint64_t size = 0;
        const char *bytes = plist_get_data_ptr(data, &size);
        *ticket = malloc(size);
        memcpy(*ticket, bytes, size);
        *ticket_size = size;
        result = 0;
    }
    plist_free(response);
    plist_free(request);
    plist_free(parameters);
    plist_free(root);
    return result;
}

#else

int vmapple_ticket_request(
    const void *manifest,
    size_t manifest_size,
    uint64_t ecid,
    const uint8_t ap_nonce[32],
    const uint8_t sep_nonce[20],
    const uint8_t *policy_digest,
    const uint8_t *next_stage_hash,
    uint8_t **ticket,
    size_t *ticket_size
) {
    return -3;
}

#endif
