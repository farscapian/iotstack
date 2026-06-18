#include "nvs_secrets.h"
#include "nvs_flash.h"
#include <cstdlib>
#include "esphome/core/component.h"
#include "esphome/core/defines.h"
#include "esphome/core/log.h"

#ifdef USE_API
#include "esphome/components/api/api_server.h"
#endif

#ifdef USE_WIFI
#include "esphome/components/wifi/wifi_component.h"
#include "esp_wifi.h"
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

  ESP_LOGI(TAG, "[NVS] Loading runtime data from NVS...");

  wifi_ssid_ = read_nvs_string("wifi_ssid");
  wifi_password_ = read_nvs_string("wifi_password");
  ota_password_ = read_nvs_string(ota_nvs_key_.c_str());
  if (!api_nvs_key_.empty())
    api_encryption_key_ = read_nvs_string(api_nvs_key_.c_str());
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
      // WiFi (priority 250) started connecting with the YAML placeholder before
      // this ran (priority 200). save_wifi_sta() saved the real credentials and
      // set connect_soon_(), but the state machine stays in its retry cycle until
      // the current attempt resolves -- which can take minutes in RETRY_HIDDEN.
      // esp_wifi_disconnect() forces an immediate DISCONNECTED event so the
      // machine idles and picks up connect_soon_() on the next loop() call.
      esp_wifi_disconnect();
    } else {
      ESP_LOGW(TAG, "[NVS] WiFi component unavailable; cannot apply NVS credentials");
    }
  }
#endif

  // Apply the Thread operational dataset from NVS (thread-only devices). The
  // OpenThread component runs at setup_priority::WIFI (250) and has already
  // initialized the stack by the time this setup runs.
  apply_thread_dataset_();
  apply_api_encryption_key_();

  ESP_LOGI(TAG, "[NVS] Setup complete");
}

void NVSSecrets::apply_api_encryption_key_() {
#ifdef USE_API_NOISE
  if (api_encryption_key_.empty()) {
    ESP_LOGD(TAG, "[NVS] No API encryption key in NVS");
    return;
  }
  if (api_encryption_key_.size() != 64) {
    ESP_LOGW(TAG, "[NVS] API encryption key has invalid length (%u); expected 64 hex chars",
             (unsigned) api_encryption_key_.size());
    return;
  }
  esphome::api::APIServer *api_server = esphome::api::global_api_server;
  if (api_server == nullptr) {
    ESP_LOGW(TAG, "[NVS] API server unavailable; cannot apply encryption key from NVS");
    return;
  }

  esphome::api::psk_t psk{};
  for (size_t i = 0; i < psk.size(); i++) {
    char byte_hex[3] = {api_encryption_key_[i * 2], api_encryption_key_[i * 2 + 1], '\0'};
    char *end = nullptr;
    unsigned long byte = strtoul(byte_hex, &end, 16);
    if (end == byte_hex || byte > 0xFF) {
      ESP_LOGW(TAG, "[NVS] API encryption key is not valid hex");
      return;
    }
    psk[i] = static_cast<uint8_t>(byte);
  }

  if (api_server->save_noise_psk(psk, true)) {
    ESP_LOGI(TAG, "[NVS] API encryption enabled (key loaded from '%s')", api_nvs_key_.c_str());
  } else {
    ESP_LOGW(TAG, "[NVS] Failed to apply API encryption key from NVS");
  }
#endif
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

void NVSSecrets::write_nvs_string(nvs_handle_t handle, const char* key, const std::string &value) {
  if (value.empty())
    return;
  esp_err_t err = nvs_set_str(handle, key, value.c_str());
  if (err != ESP_OK)
    ESP_LOGW(TAG, "[NVS-UPDATE] write '%s' failed: %s", key, esp_err_to_name(err));
  else
    ESP_LOGI(TAG, "[NVS-UPDATE] '%s' updated", key);
}

void NVSSecrets::write_nvs_u8_if_set(nvs_handle_t handle, const char* key, const std::string &value) {
  if (value.empty())
    return;
  int parsed = atoi(value.c_str());
  if (parsed < 1 || parsed > 2) {
    ESP_LOGW(TAG, "[NVS-UPDATE] invalid %s=%s (expected 1 or 2)", key, value.c_str());
    return;
  }
  uint8_t v = static_cast<uint8_t>(parsed);
  esp_err_t err = nvs_set_u8(handle, key, v);
  if (err != ESP_OK)
    ESP_LOGW(TAG, "[NVS-UPDATE] write '%s' failed: %s", key, esp_err_to_name(err));
  else
    ESP_LOGI(TAG, "[NVS-UPDATE] '%s' updated to %u", key, v);
}

void NVSSecrets::write_nvs_u16_if_set(nvs_handle_t handle, const char* key, const std::string &value, uint16_t max_val) {
  if (value.empty())
    return;
  int parsed = atoi(value.c_str());
  if (parsed < 8 || parsed > max_val) {
    ESP_LOGW(TAG, "[NVS-UPDATE] invalid %s=%s (expected 8-%u)", key, value.c_str(), max_val);
    return;
  }
  uint16_t v = static_cast<uint16_t>(parsed);
  esp_err_t err = nvs_set_u16(handle, key, v);
  if (err != ESP_OK)
    ESP_LOGW(TAG, "[NVS-UPDATE] write '%s' failed: %s", key, esp_err_to_name(err));
  else
    ESP_LOGI(TAG, "[NVS-UPDATE] '%s' updated to %u", key, v);
}

void NVSSecrets::update_secrets(const std::string &wifi_ssid,
                                const std::string &wifi_password,
                                const std::string &ota_password,
                                const std::string &api_key,
                                const std::string &thread_tlv,
                                const std::string &matrix_cols,
                                const std::string &matrix_panel_w,
                                const std::string &matrix_panel_h,
                                const std::string &device_role) {
  nvs_handle_t handle;
  esp_err_t err = nvs_open(NAMESPACE, NVS_READWRITE, &handle);
  if (err != ESP_OK) {
    ESP_LOGE(TAG, "[NVS-UPDATE] Failed to open NVS for writing: %s", esp_err_to_name(err));
    return;
  }
  write_nvs_string(handle, "wifi_ssid",     wifi_ssid);
  write_nvs_string(handle, "wifi_password", wifi_password);
  write_nvs_string(handle, "ota_password",  ota_password);
  if (!api_nvs_key_.empty())
    write_nvs_string(handle, api_nvs_key_.c_str(), api_key);
  write_nvs_string(handle, "thread_tlv",    thread_tlv);
  write_nvs_u8_if_set(handle, "matrix_cols", matrix_cols);
  write_nvs_u16_if_set(handle, "matrix_panel_w", matrix_panel_w, 256);
  write_nvs_u16_if_set(handle, "matrix_panel_h", matrix_panel_h, 128);
  write_nvs_string(handle, "device_role", device_role);
  err = nvs_commit(handle);
  if (err != ESP_OK)
    ESP_LOGE(TAG, "[NVS-UPDATE] nvs_commit failed: %s", esp_err_to_name(err));
  else
    ESP_LOGI(TAG, "[NVS-UPDATE] NVS commit successful; reboot to apply");
  nvs_close(handle);
}

void NVSSecrets::dump_config() {
  ESP_LOGCONFIG(TAG, "NVS Runtime Data:");
#ifdef USE_WIFI
  ESP_LOGCONFIG(TAG, "  WiFi SSID: %s", wifi_ssid_.empty() ? "(not set)" : "(loaded from NVS)");
  ESP_LOGCONFIG(TAG, "  WiFi Password: %s", wifi_password_.empty() ? "(not set)" : "(loaded from NVS)");
#endif
  ESP_LOGCONFIG(TAG, "  OTA key '%s': %s", ota_nvs_key_.c_str(), ota_password_.empty() ? "(not set)" : "(loaded from NVS)");
  if (!api_nvs_key_.empty())
    ESP_LOGCONFIG(TAG, "  API key '%s': %s", api_nvs_key_.c_str(), api_encryption_key_.empty() ? "(not set)" : "(loaded from NVS)");
#ifdef USE_OPENTHREAD
  ESP_LOGCONFIG(TAG, "  Thread TLV: %s", thread_tlv_.empty() ? "(not set)" : "(loaded from NVS)");
#endif
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
