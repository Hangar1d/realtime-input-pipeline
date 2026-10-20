#include "PipelineCore.h"
#include <stddef.h>

int main(void) {
    RIPStatus status = RIP_INTERNAL_ERROR;
    RIPConfig config = rip_default_config();
    RIPCore* core = rip_core_create(config, &status);
    RIPMetrics metrics = {0};
    if (core == NULL || status != RIP_OK) return 1;
    if (rip_core_metrics(core, &metrics) != RIP_OK || metrics.terminal != 0) return 2;
    if (rip_core_cancel(core) != RIP_OK) return 3;
    rip_core_destroy(core);
    rip_core_destroy(NULL);
    return 0;
}
