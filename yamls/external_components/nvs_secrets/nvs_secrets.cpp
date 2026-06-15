#include "nvs_secrets.h"
#include "nvs_flash.h"
#include "esphome/core/defines.h"
#include "esphome/core/log.h"

#ifdef USE_WIFI
#include "esphome/components/wifi/wifi_component.h"
#endif

#ifdef USE_OPENTHREAD
#include "esphome/components/openthread/openthread.h"
#include <openthread/dataset.h>
#include <openthread/thread.h>
#include <openthread/ip6.h>
#include <openthread/error.h>
#include <cstdlib>
#endif

namespace esphome {
namespace nvs_secrets {

static const char* const TAG = "nvs_secrets";
static const char* const NAMESPACE = "iotstack";  // Must match namespace row in write-nvs-secrets.sh CSV

std::string NVSSecrets::read_nvs_string(const char* key) {
  nvs_handle_t nvs_handle;
  esp_err_t err = nvs_open(NAMESPACE, NVS_READONLY, &nvs_handle);

  if (err != ESP_OK) {
    ESP_LOGW(TAG, "Failed to open NVS namespace '%s': %s", NAMESPACE, esp_err_to_name(err));
    return "";
  }

  size_t required_size = 0;
  err = nvs_get_str(nvs_handle, key, nullptr, &required_size);

  if (err == ESP_ERR_NVS_NOT_FOUND) {
    ESP_LOGW(TAG, "NVS key not found: %s", key);
    nvs_close(nvs_handle);
    return "";
  } else if (err != ESP_OK) {
    ESP_LOGW(TAG, "Failed to read NVS key %s: %s", key, esp_err_to_name(err));
    nvs_close(nvs_handle);
    return "";
  }

  std::string value(required_size, '\0');
  err = nvs_get_str(nvs_handle, key, &value[0], &required_size);

  if (err != ESP_OK) {
    ESP_LOGW(TAG, "Failed to read NVS value for key %s: %s", key, esp_err_to_name(err));
    nvs_close(nvs_handle);
    return "";
  }

  nvs_close(nvs_handle);
  value.resize(required_size - 1);  // Remove null terminator
  return value;
}

void NVSSecrets::setup() {
  ESP_LOGI(TAG, "[NVS] Component setup started");

  // Initialize NVS flash (required before any NVS operations)
  esp_err_t err = nvs_flash_init();
  if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
    ESP_LOGW(TAG, "[NVS] NVS partition corrupted, erasing and reinitializing...");
    nvs_flash_erase();
    err = nvs_flash_init();
  }

  if (err != ESP_OK) {
    ESP_LOGE(TAG, "[NVS] Failed to initialize NVS flash: %s", esp_err_to_name(err));
    return;
  }

  ESP_LOGI(TAG, "[NVS] Loading secrets from NVS...");

  wifi_ssid_ = read_nvs_string("wifi_ssid");
  wifi_password_ = read_nvs_string("wifi_password");
  ota_password_ = read_nvs_string("ota_password");
  api_encryption_key_ = read_nvs_string("api_key");
  thread_tlv_ = read_nvs_string("thread_tlv");

  if (!wifi_ssid_.empty()) {
    ESP_LOGI(TAG, "[NVS] WiFi SSID loaded: %s", wifi_ssid_.c_str());
  } else {
    ESP_LOGW(TAG, "[NVS] WiFi SSID NOT in NVS");
  }

  // Apply WiFi credentials from NVS to the WiFi component.
  // nvs_secrets runs at setup_priority AFTER_WIFI (200), so the WiFi component
  // (priority 250) is already initialized here. save_wifi_sta() replaces the
  // STA config with the NVS values and triggers an immediate reconnect, which
  // overrides the YAML placeholder ("configured-via-nvs").
#ifdef USE_WIFI
  if (!wifi_ssid_.empty()) {
    if (wifi::global_wifi_component != nullptr) {
      ESP_LOGI(TAG, "[NVS] Applying WiFi credentials from NVS to WiFi component (SSID: %s)", wifi_ssid_.c_str());
      wifi::global_wifi_component->save_wifi_sta(wifi_ssid_, wifi_password_);
    } else {
      ESP_LOGW(TAG, "[NVS] WiFi component unavailable; cannot apply NVS credentials");
    }
  }
#endif

  // Apply the Thread operational dataset from NVS (thread-only devices). The
  // OpenThread component runs at setup_priority::WIFI (250) and has already
  // initialized the stack by the time this AFTER_WIFI (200) setup runs.
  apply_thread_dataset_();

  ESP_LOGI(TAG, "[NVS] Setup complete");
}

void NVSSecrets::apply_thread_dataset_() {
#ifdef USE_OPENTHREAD
  if (thread_tlv_.empty()) {
    ESP_LOGW(TAG, "[NVS] Thread TLV NOT in NVS - device using YAML placeholder dataset");
    return;
  }
  if (thread_tlv_.size() % 2 != 0) {
    ESP_LOGE(TAG, "[NVS] Thread TLV hex length is odd (%u); ignoring", (unsigned) thread_tlv_.size());
    return;
  }

  // Parse the hex string into an operational dataset TLV blob.
  otOperationalDatasetTlvs dataset = {};
  size_t len = thread_tlv_.size() / 2;
  if (len > sizeof(dataset.mTlvs)) {
    ESP_LOGW(TAG, "[NVS] Thread TLV too long (%u > %u); truncating", (unsigned) len,
             (unsigned) sizeof(dataset.mTlvs));
    len = sizeof(dataset.mTlvs);
  }
  for (size_t i = 0; i < len; i++) {
    char byte_hex[3] = {thread_tlv_[i * 2], thread_tlv_[i * 2 + 1], '\0'};
    dataset.mTlvs[i] = (uint8_t) strtoul(byte_hex, nullptr, 16);
  }
  dataset.mLength = (uint8_t) len;

  ESP_LOGI(TAG, "[NVS] Applying Thread dataset from NVS (%u TLV bytes)", (unsigned) len);

  // OpenThread APIs are not thread-safe; take the stack lock first.
  auto lock = openthread::InstanceLock::acquire();
  otInstance *inst = lock.get_instance();
  if (inst == nullptr) {
    ESP_LOGE(TAG, "[NVS] OpenThread instance unavailable; cannot apply dataset");
    return;
  }

  // Switch the active dataset, then (re)enable the stack so the device attaches
  // to the network described by the NVS dataset (overriding the placeholder).
  otThreadSetEnabled(inst, false);
  otError err = otDatasetSetActiveTlvs(inst, &dataset);
  if (err != OT_ERROR_NONE) {
    ESP_LOGE(TAG, "[NVS] otDatasetSetActiveTlvs failed: %s", otThreadErrorToString(err));
    otThreadSetEnabled(inst, true);
    return;
  }
  otIp6SetEnabled(inst, true);
  otThreadSetEnabled(inst, true);
  ESP_LOGI(TAG, "[NVS] Thread dataset applied; (re)attaching to the Thread network");
#endif
}

void NVSSecrets::dump_config() {
  ESP_LOGCONFIG(TAG, "NVS Secrets Component:");
  ESP_LOGCONFIG(TAG, "  WiFi SSID: %s", wifi_ssid_.empty() ? "(not set)" : "(loaded from NVS)");
  ESP_LOGCONFIG(TAG, "  WiFi Password: %s", wifi_password_.empty() ? "(not set)" : "(loaded from NVS)");
  ESP_LOGCONFIG(TAG, "  OTA Password: %s", ota_password_.empty() ? "(not set)" : "(loaded from NVS)");
  ESP_LOGCONFIG(TAG, "  API Key: %s", api_encryption_key_.empty() ? "(not set)" : "(loaded from NVS)");
  ESP_LOGCONFIG(TAG, "  Thread TLV: %s", thread_tlv_.empty() ? "(not set)" : "(loaded from NVS)");
}

void NVSSecrets::loop() {
  if (logged_status_)
    return;
  logged_status_ = true;
#ifdef USE_WIFI
  if (!wifi_ssid_.empty()) {
    ESP_LOGI(TAG, "[NVS-STATUS] WiFi SSID successfully loaded from NVS: %s", wifi_ssid_.c_str());
  } else {
    ESP_LOGW(TAG, "[NVS-STATUS] WiFi SSID NOT FOUND in NVS - device using YAML placeholder");
  }
#endif
#ifdef USE_OPENTHREAD
  if (!thread_tlv_.empty()) {
    ESP_LOGI(TAG, "[NVS-STATUS] Thread dataset loaded from NVS (%u hex chars)", (unsigned) thread_tlv_.size());
  } else {
    ESP_LOGW(TAG, "[NVS-STATUS] Thread TLV NOT FOUND in NVS - device using YAML placeholder");
  }
#endif
}

}  // namespace nvs_secrets
}  // namespace esphome
