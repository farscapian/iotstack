#include "nvs_secrets.h"
#include "nvs_flash.h"
#include "esphome/core/log.h"

namespace esphome {
namespace nvs_secrets {

static const char* const TAG = "nvs_secrets";
static const char* const NAMESPACE = "";  // Keys stored in default NVS namespace by nvs_partition_gen

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
  ESP_LOGI(TAG, "=== NVS SECRETS COMPONENT INITIALIZING (setup priority 200) ===");

  // Initialize NVS flash (required before any NVS operations)
  esp_err_t err = nvs_flash_init();
  if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
    ESP_LOGW(TAG, "NVS partition corrupted or version mismatch, erasing and reinitializing...");
    nvs_flash_erase();
    err = nvs_flash_init();
  }

  if (err != ESP_OK) {
    ESP_LOGE(TAG, "Failed to initialize NVS flash: %s", esp_err_to_name(err));
    return;
  }

  ESP_LOGI(TAG, "NVS flash initialized, loading device-specific secrets...");

  wifi_ssid_ = read_nvs_string("wifi_ssid");
  if (!wifi_ssid_.empty()) {
    ESP_LOGI(TAG, "[CRITICAL] WiFi SSID loaded from NVS: %s (%zu bytes)", wifi_ssid_.c_str(), wifi_ssid_.length());
  } else {
    ESP_LOGW(TAG, "[CRITICAL] WiFi SSID NOT found in NVS - device will use YAML placeholder");
  }

  wifi_password_ = read_nvs_string("wifi_password");
  if (!wifi_password_.empty()) {
    ESP_LOGI(TAG, "✓ WiFi password loaded from NVS (%zu bytes)", wifi_password_.length());
  } else {
    ESP_LOGW(TAG, "✗ WiFi password not found in NVS");
  }

  ota_password_ = read_nvs_string("ota_password");
  if (!ota_password_.empty()) {
    ESP_LOGI(TAG, "✓ OTA password loaded from NVS (%zu bytes)", ota_password_.length());
  } else {
    ESP_LOGW(TAG, "✗ OTA password not found in NVS");
  }

  api_encryption_key_ = read_nvs_string("api_key");
  if (!api_encryption_key_.empty()) {
    ESP_LOGI(TAG, "✓ API encryption key loaded from NVS (%zu bytes)", api_encryption_key_.length());
  } else {
    ESP_LOGW(TAG, "✗ API encryption key not found in NVS");
  }

  ESP_LOGI(TAG, "=== NVS SECRETS COMPONENT READY ===");
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
