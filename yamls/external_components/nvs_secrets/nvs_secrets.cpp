#include "nvs_secrets.h"
#include "nvs_flash.h"
#include "esphome/core/defines.h"
#include "esphome/core/log.h"

#ifdef USE_WIFI
#include "esphome/components/wifi/wifi_component.h"
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

  ESP_LOGI(TAG, "[NVS] Setup complete");
}

void NVSSecrets::dump_config() {
  ESP_LOGCONFIG(TAG, "NVS Secrets Component:");
  ESP_LOGCONFIG(TAG, "  WiFi SSID: %s", wifi_ssid_.empty() ? "(not set)" : "(loaded from NVS)");
  ESP_LOGCONFIG(TAG, "  WiFi Password: %s", wifi_password_.empty() ? "(not set)" : "(loaded from NVS)");
  ESP_LOGCONFIG(TAG, "  OTA Password: %s", ota_password_.empty() ? "(not set)" : "(loaded from NVS)");
  ESP_LOGCONFIG(TAG, "  API Key: %s", api_encryption_key_.empty() ? "(not set)" : "(loaded from NVS)");
}

void NVSSecrets::loop() {
  if (!logged_status_) {
    logged_status_ = true;
    if (!wifi_ssid_.empty()) {
      ESP_LOGI(TAG, "[NVS-STATUS] WiFi SSID successfully loaded from NVS: %s", wifi_ssid_.c_str());
    } else {
      ESP_LOGW(TAG, "[NVS-STATUS] WiFi SSID NOT FOUND in NVS - device using YAML placeholder");
    }
  }
}

}  // namespace nvs_secrets
}  // namespace esphome
