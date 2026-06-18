#pragma once
// Forward-declare ESP-IDF mdns_service_remove() at file scope so ESPHome
// lambdas can call it. The function is in esp-idf's mdns library but its
// header is only included in mDNS component .cpp files, not the shared header.
#include "esp_err.h"
extern "C" esp_err_t mdns_service_remove(const char *service_type, const char *proto);