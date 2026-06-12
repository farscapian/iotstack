#include "nvs_secrets.h"
#include "esphome/core/log.h"

namespace esphome {
namespace nvs_secrets {

static const char* const TAG = "nvs_secrets";

std::string NVSSecrets::read_nvs_string(const char* key) {
  nvs_handle_t nvs_handle;
  esp_err_t err = nvs_open("nvs_secrets", NVS_READONLY, &nvs_handle);

  if (err != ESP_OK) {
    ESP_LOGW(TAG, "Failed to open NVS namespace: %s", esp_err_to_name(err));
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
  ESP_LOGI(TAG, "Loading device-specific secrets from NVS...");

  wifi_ssid_ = read_nvs_string("wifi_ssid");
  wifi_password_ = read_nvs_string("wifi_password");
  ota_password_ = read_nvs_string("ota_password");
  api_encryption_key_ = read_nvs_string("api_key");

  // Apply WiFi credentials to WiFi component
  if (!wifi_ssid_.empty() && !wifi_password_.empty()) {
    auto* wifi = wifi::global_wifi_component;
    if (wifi) {
      wifi::WiFiNetwork network;
      network.ssid = wifi_ssid_;
      network.password = wifi_password_;
      wifi->clear_networks();
      wifi->add_network(network);
      ESP_LOGI(TAG, "WiFi credentials applied from NVS: SSID='%s'", wifi_ssid_.c_str());
    }
  } else {
    if (wifi_ssid_.empty()) {
      ESP_LOGW(TAG, "WiFi SSID not found in NVS");
    }
    if (wifi_password_.empty()) {
      ESP_LOGW(TAG, "WiFi password not found in NVS");
    }
  }

  // Apply API encryption key if available
  if (!api_encryption_key_.empty()) {
    auto* api_server = api::global_api_server;
    if (api_server) {
      api_server->set_encryption_key(api_encryption_key_);
      ESP_LOGI(TAG, "API encryption key applied from NVS");
    }
  } else {
    ESP_LOGW(TAG, "API encryption key not found in NVS");
  }

  if (!ota_password_.empty()) {
    ESP_LOGI(TAG, "OTA password loaded from NVS");
  } else {
    ESP_LOGW(TAG, "OTA password not found in NVS");
  }
}

void NVSSecrets::dump_config() {
  ESP_LOGCONFIG(TAG, "NVS Secrets Component:");
  ESP_LOGCONFIG(TAG, "  WiFi SSID: %s", wifi_ssid_.empty() ? "(not set)" : "(loaded from NVS)");
  ESP_LOGCONFIG(TAG, "  WiFi Password: %s", wifi_password_.empty() ? "(not set)" : "(loaded from NVS)");
  ESP_LOGCONFIG(TAG, "  OTA Password: %s", ota_password_.empty() ? "(not set)" : "(loaded from NVS)");
  ESP_LOGCONFIG(TAG, "  API Key: %s", api_encryption_key_.empty() ? "(not set)" : "(loaded from NVS)");
}

}  // namespace nvs_secrets
}  // namespace esphome
