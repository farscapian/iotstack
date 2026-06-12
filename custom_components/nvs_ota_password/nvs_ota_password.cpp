#include "nvs_ota_password.h"
#include "esphome/core/log.h"

namespace esphome {
namespace nvs_ota_password {

static const char* const TAG = "nvs_ota_password";

std::string NVSOtaPassword::read_nvs_string(const char* key) {
  nvs_handle_t nvs_handle;
  esp_err_t err = nvs_open("iotstack", NVS_READONLY, &nvs_handle);

  if (err != ESP_OK) {
    ESP_LOGW(TAG, "Failed to open NVS namespace 'iotstack': %s", esp_err_to_name(err));
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

void NVSOtaPassword::setup() {
  ESP_LOGI(TAG, "Verifying device-specific OTA password in NVS...");

  std::string ota_password = read_nvs_string("ota_password");

  if (ota_password.empty()) {
    ESP_LOGW(TAG, "OTA password not found in NVS - OTA will not be available");
    return;
  }

  // Password is loaded from NVS by the OTA service at startup
  // This component verifies it's present and accessible
  ESP_LOGI(TAG, "OTA password verified in NVS (%zu bytes)", ota_password.length());
  ESP_LOGD(TAG, "OTA service will use password from NVS at authentication time");
}

void NVSOtaPassword::dump_config() {
  ESP_LOGCONFIG(TAG, "NVS OTA Password:");
  std::string ota_password = read_nvs_string("ota_password");
  ESP_LOGCONFIG(TAG, "  OTA Password: %s", ota_password.empty() ? "(not set)" : "(loaded from NVS)");
}

}  // namespace nvs_ota_password
}  // namespace esphome
