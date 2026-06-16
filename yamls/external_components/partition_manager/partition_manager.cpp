#include "partition_manager.h"
#include "esphome/core/application.h"
#include "esphome/core/log.h"
#include "esp_ota_ops.h"
#include "esp_partition.h"

namespace esphome {
namespace partition_manager {

static const char *const TAG = "partition";

void PartitionManager::handle_button_press() {
  this->press_time_ = millis();
  ESP_LOGI(TAG, "Boot button pressed - release to restart, or hold 3s to toggle boot partition");
}

void PartitionManager::handle_button_release() {
  uint32_t hold = millis() - this->press_time_;
  if (hold >= 3000) {
    ESP_LOGI(TAG, "Long press detected (%.1fs) - attempting partition switch", hold / 1000.0f);
    this->toggle_boot_partition();
  } else if (hold >= 50) {
    // Short press: graceful restart. On the native USB-Serial/JTAG this is a
    // soft reset that keeps the USB CDC alive, so an attached log session
    // survives the reboot. Does not change the boot partition.
    ESP_LOGI(TAG, "Short press (%ums) - restarting device", (unsigned) hold);
    App.safe_reboot();
  }
}

void PartitionManager::toggle_boot_partition() {
  const esp_partition_t *running = esp_ota_get_running_partition();
  const esp_partition_t *next;
  if (running->subtype == ESP_PARTITION_SUBTYPE_APP_OTA_0) {
    next = esp_partition_find_first(ESP_PARTITION_TYPE_APP, ESP_PARTITION_SUBTYPE_APP_OTA_1, nullptr);
  } else {
    next = esp_partition_find_first(ESP_PARTITION_TYPE_APP, ESP_PARTITION_SUBTYPE_APP_OTA_0, nullptr);
  }

  if (next == nullptr) {
    ESP_LOGE(TAG, "Failed to find alternate partition");
    return;
  }

  // Verify the target holds a valid app image first. Without this check
  // esp_ota_set_boot_partition() "succeeds", but the bootloader rejects an
  // empty/invalid image and silently falls back to failsafe.
  esp_app_desc_t app_desc;
  esp_err_t img_err = esp_ota_get_partition_description(next, &app_desc);
  if (img_err != ESP_OK) {
    ESP_LOGW(TAG, "No valid image on '%s' (%s) - NOT switching", next->label, esp_err_to_name(img_err));
    ESP_LOGW(TAG, "Boot partition remains in FAILSAFE mode. Flash production firmware first.");
    return;
  }

  esp_ota_set_boot_partition(next);
  ESP_LOGI(TAG, "Boot partition switched to: %s — %s v%s - restart to apply",
           next->label, app_desc.project_name, app_desc.version);
}

void PartitionManager::boot_failsafe() {
  const esp_partition_t *running = esp_ota_get_running_partition();
  if (running != nullptr && running->subtype == ESP_PARTITION_SUBTYPE_APP_OTA_0) {
    ESP_LOGI(TAG, "Already running failsafe (ota_0); no switch needed");
    return;
  }
  const esp_partition_t *fs =
      esp_partition_find_first(ESP_PARTITION_TYPE_APP, ESP_PARTITION_SUBTYPE_APP_OTA_0, nullptr);
  if (fs == nullptr) {
    ESP_LOGE(TAG, "Failsafe partition (ota_0) not found");
    return;
  }
  esp_ota_set_boot_partition(fs);
  ESP_LOGW(TAG, "Switching to failsafe (ota_0) and rebooting for OTA update");
  App.safe_reboot();
}

}  // namespace partition_manager
}  // namespace esphome
