#include "partition_manager.h"
#include "esphome/core/application.h"
#include "esphome/core/log.h"
#include "esp_ota_ops.h"
#include "esp_partition.h"
#include <cstdio>
#include <cstring>
#include <vector>

namespace esphome {
namespace partition_manager {

static const char *const TAG = "partition";

namespace {

bool looks_like_esphome_build_time_(const char *s, size_t avail) {
  // ESPHome embeds ESPHOME_BUILD_TIME_STR as "YYYY-MM-DD HH:MM:SS ..."
  if (avail < 19)
    return false;
  return s[0] == '2' && s[1] == '0' && s[4] == '-' && s[7] == '-' && s[10] == ' ';
}

bool read_uint32_at_(const uint8_t *data, size_t size, size_t pos, uint32_t *out) {
  if (pos + 4 > size)
    return false;
  memcpy(out, data + pos, 4);
  return true;
}

bool format_hash_(uint32_t hash, char *buf, size_t buflen) {
  if (hash == 0 || hash == 0xffffffffU)
    return false;
  snprintf(buf, buflen, "%08x", (unsigned) hash);
  return true;
}

bool calibrate_hash_offset_(const uint8_t *data, size_t size, uint32_t expected_hash, int *out_offset) {
  for (size_t i = 0; i + 19 < size; i++) {
    if (!looks_like_esphome_build_time_(reinterpret_cast<const char *>(data + i), size - i))
      continue;
    for (int off = -32; off <= 48; off += 4) {
      uint32_t candidate = 0;
      if (!read_uint32_at_(data, size, i + off, &candidate))
        continue;
      if (candidate == expected_hash) {
        *out_offset = off;
        return true;
      }
    }
  }
  return false;
}

bool find_config_hash_in_partition_(const esp_partition_t *part, uint32_t *out_hash) {
  if (part == nullptr || out_hash == nullptr)
    return false;

  esp_app_desc_t desc;
  if (esp_ota_get_partition_description(part, &desc) != ESP_OK)
    return false;

  std::vector<uint8_t> image(part->size);
  if (esp_partition_read(part, 0, image.data(), part->size) != ESP_OK)
    return false;

  for (size_t i = 0; i + 19 < image.size(); i++) {
    if (!looks_like_esphome_build_time_(reinterpret_cast<const char *>(image.data() + i), image.size() - i))
      continue;
    for (int off = -32; off <= 48; off += 4) {
      uint32_t candidate = 0;
      if (!read_uint32_at_(image.data(), image.size(), i + off, &candidate))
        continue;
      if (candidate == 0 || candidate == 0xffffffffU)
        continue;
      *out_hash = candidate;
      return true;
    }
  }
  return false;
}

const esp_partition_t *alternate_ota_partition_(const esp_partition_t *running) {
  if (running == nullptr)
    return nullptr;
  if (running->subtype == ESP_PARTITION_SUBTYPE_APP_OTA_0) {
    return esp_partition_find_first(ESP_PARTITION_TYPE_APP, ESP_PARTITION_SUBTYPE_APP_OTA_1, nullptr);
  }
  return esp_partition_find_first(ESP_PARTITION_TYPE_APP, ESP_PARTITION_SUBTYPE_APP_OTA_0, nullptr);
}

bool read_config_hash_with_calibration_(const esp_partition_t *running, const esp_partition_t *alt,
                                        uint32_t running_hash, uint32_t *alt_hash) {
  if (running == nullptr || alt == nullptr || alt_hash == nullptr)
    return false;

  std::vector<uint8_t> running_image(running->size);
  std::vector<uint8_t> alt_image(alt->size);
  if (esp_partition_read(running, 0, running_image.data(), running->size) != ESP_OK)
    return false;
  esp_app_desc_t alt_desc;
  if (esp_ota_get_partition_description(alt, &alt_desc) != ESP_OK)
    return false;
  if (esp_partition_read(alt, 0, alt_image.data(), alt->size) != ESP_OK)
    return false;

  int calibrated_off = 0;
  if (!calibrate_hash_offset_(running_image.data(), running_image.size(), running_hash, &calibrated_off)) {
    return find_config_hash_in_partition_(alt, alt_hash);
  }

  for (size_t i = 0; i + 19 < alt_image.size(); i++) {
    if (!looks_like_esphome_build_time_(reinterpret_cast<const char *>(alt_image.data() + i), alt_image.size() - i))
      continue;
    uint32_t candidate = 0;
    if (!read_uint32_at_(alt_image.data(), alt_image.size(), i + calibrated_off, &candidate))
      continue;
    if (candidate == 0 || candidate == 0xffffffffU)
      continue;
    *alt_hash = candidate;
    return true;
  }
  return find_config_hash_in_partition_(alt, alt_hash);
}

}  // namespace

void PartitionManager::refresh_image_hashes_() {
  const uint32_t running_hash = App.get_config_hash();
  const esp_partition_t *running = esp_ota_get_running_partition();
  const esp_partition_t *alt = alternate_ota_partition_(running);

  char running_buf[9] = {};
  char alt_buf[9] = {};
  format_hash_(running_hash, running_buf, sizeof(running_buf));

  uint32_t alt_hash = 0;
  const bool have_alt = read_config_hash_with_calibration_(running, alt, running_hash, &alt_hash);
  if (have_alt)
    format_hash_(alt_hash, alt_buf, sizeof(alt_buf));

  const bool on_bootstrap = running != nullptr && running->subtype == ESP_PARTITION_SUBTYPE_APP_OTA_0;
  bootstrap_image_hash_ = on_bootstrap ? running_buf : (have_alt ? alt_buf : "");
  production_image_hash_ = on_bootstrap ? (have_alt ? alt_buf : "") : running_buf;

  ESP_LOGI(TAG, "Image hashes: bootstrap=%s production=%s",
           bootstrap_image_hash_.empty() ? "-" : bootstrap_image_hash_.c_str(),
           production_image_hash_.empty() ? "-" : production_image_hash_.c_str());
}

void PartitionManager::setup() {
  this->refresh_image_hashes_();
}

void PartitionManager::handle_button_press() {
  this->press_time_ = millis();
  this->button_held_ = true;
  this->long_press_triggered_ = false;
  ESP_LOGI(TAG, "Boot button pressed - release to restart, or hold 3s to switch partition and reboot");
}

void PartitionManager::handle_button_release() {
  this->button_held_ = false;
  if (this->long_press_triggered_)
    return;  // loop() already fired the reboot; ignore release
  uint32_t hold = millis() - this->press_time_;
  if (hold >= 50) {
    ESP_LOGI(TAG, "Short press (%ums) - restarting device", (unsigned) hold);
    App.safe_reboot();
  }
}

void PartitionManager::loop() {
  if (!this->button_held_ || this->long_press_triggered_)
    return;
  if (millis() - this->press_time_ >= 3000) {
    this->long_press_triggered_ = true;
    ESP_LOGI(TAG, "3s hold threshold reached - switching partition and rebooting");
    this->toggle_boot_partition();
  }
}

void PartitionManager::toggle_boot_partition() {
  const esp_partition_t *running = esp_ota_get_running_partition();
  const esp_partition_t *next = alternate_ota_partition_(running);

  if (next == nullptr) {
    ESP_LOGE(TAG, "Failed to find alternate partition");
    return;
  }

  // Verify the target holds a valid app image first. Without this check
  // esp_ota_set_boot_partition() "succeeds", but the bootloader rejects an
  // empty/invalid image and silently falls back to bootstrap.
  esp_app_desc_t app_desc;
  esp_err_t img_err = esp_ota_get_partition_description(next, &app_desc);
  if (img_err != ESP_OK) {
    ESP_LOGW(TAG, "No valid image on '%s' (%s) - NOT switching", next->label, esp_err_to_name(img_err));
    ESP_LOGW(TAG, "Boot partition remains in BOOTSTRAP mode. Flash production firmware first.");
    return;
  }

  esp_ota_set_boot_partition(next);
  ESP_LOGI(TAG, "Boot partition switched to: %s -- %s v%s - rebooting now",
           next->label, app_desc.project_name, app_desc.version);
  App.safe_reboot();
}

void PartitionManager::boot_bootstrap() {
  const esp_partition_t *running = esp_ota_get_running_partition();
  if (running != nullptr && running->subtype == ESP_PARTITION_SUBTYPE_APP_OTA_0) {
    ESP_LOGI(TAG, "Already running bootstrap (ota_0); no switch needed");
    return;
  }
  const esp_partition_t *bs =
      esp_partition_find_first(ESP_PARTITION_TYPE_APP, ESP_PARTITION_SUBTYPE_APP_OTA_0, nullptr);
  if (bs == nullptr) {
    ESP_LOGE(TAG, "Bootstrap partition (ota_0) not found");
    return;
  }
  esp_ota_set_boot_partition(bs);
  ESP_LOGW(TAG, "Switching to bootstrap (ota_0) and rebooting for OTA update");
  App.safe_reboot();
}

}  // namespace partition_manager
}  // namespace esphome