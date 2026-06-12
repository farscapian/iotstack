#include "nvs_writer.h"
#include "esphome/core/log.h"

namespace esphome {
namespace nvs_writer {

static const char* const TAG = "nvs_writer";

void NVSWriter::setup() {
  ESP_LOGD(TAG, "Initializing NVS Writer");

  // Initialize NVS
  esp_err_t err = nvs_flash_init();
  if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
    ESP_LOGW(TAG, "NVS partition needs formatting, erasing...");
    ESP_ERROR_CHECK(nvs_flash_erase());
    err = nvs_flash_init();
  }
  ESP_ERROR_CHECK(err);

  ESP_LOGI(TAG, "NVS Writer initialized");
}

void NVSWriter::dump_config() {
  ESP_LOGCONFIG(TAG, "NVS Writer:");
  ESP_LOGCONFIG(TAG, "  Namespace: %s", nvs_namespace_);
}

void NVSWriter::write_string(const std::string& key, const std::string& value) {
  esp_err_t err = nvs_open(nvs_namespace_, NVS_READWRITE, &nvs_handle_);
  if (err != ESP_OK) {
    ESP_LOGE(TAG, "Failed to open NVS namespace: %s", esp_err_to_name(err));
    return;
  }

  err = nvs_set_str(nvs_handle_, key.c_str(), value.c_str());
  if (err != ESP_OK) {
    ESP_LOGE(TAG, "Failed to write NVS key '%s': %s", key.c_str(), esp_err_to_name(err));
    nvs_close(nvs_handle_);
    return;
  }

  err = nvs_commit(nvs_handle_);
  if (err != ESP_OK) {
    ESP_LOGE(TAG, "Failed to commit NVS: %s", esp_err_to_name(err));
  } else {
    ESP_LOGI(TAG, "NVS key '%s' written successfully", key.c_str());
  }

  nvs_close(nvs_handle_);
}

void NVSWriter::write_nvs_data(const std::vector<std::pair<std::string, std::string>>& data) {
  esp_err_t err = nvs_open(nvs_namespace_, NVS_READWRITE, &nvs_handle_);
  if (err != ESP_OK) {
    ESP_LOGE(TAG, "Failed to open NVS namespace: %s", esp_err_to_name(err));
    return;
  }

  for (const auto& pair : data) {
    err = nvs_set_str(nvs_handle_, pair.first.c_str(), pair.second.c_str());
    if (err != ESP_OK) {
      ESP_LOGE(TAG, "Failed to write NVS key '%s': %s", pair.first.c_str(), esp_err_to_name(err));
    } else {
      ESP_LOGD(TAG, "NVS key '%s' written", pair.first.c_str());
    }
  }

  err = nvs_commit(nvs_handle_);
  if (err != ESP_OK) {
    ESP_LOGE(TAG, "Failed to commit NVS: %s", esp_err_to_name(err));
  } else {
    ESP_LOGI(TAG, "NVS batch write committed successfully (%zu keys)", data.size());
  }

  nvs_close(nvs_handle_);
}

void NVSWriter::erase_key(const std::string& key) {
  esp_err_t err = nvs_open(nvs_namespace_, NVS_READWRITE, &nvs_handle_);
  if (err != ESP_OK) {
    ESP_LOGE(TAG, "Failed to open NVS namespace: %s", esp_err_to_name(err));
    return;
  }

  err = nvs_erase_key(nvs_handle_, key.c_str());
  if (err != ESP_OK) {
    ESP_LOGE(TAG, "Failed to erase NVS key '%s': %s", key.c_str(), esp_err_to_name(err));
    nvs_close(nvs_handle_);
    return;
  }

  err = nvs_commit(nvs_handle_);
  if (err != ESP_OK) {
    ESP_LOGE(TAG, "Failed to commit NVS: %s", esp_err_to_name(err));
  } else {
    ESP_LOGI(TAG, "NVS key '%s' erased successfully", key.c_str());
  }

  nvs_close(nvs_handle_);
}

}  // namespace nvs_writer
}  // namespace esphome
