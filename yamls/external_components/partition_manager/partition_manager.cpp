#include "partition_manager.h"
#include "esphome/core/application.h"
#include "esphome/core/log.h"
#include "esp_ota_ops.h"
#include "esp_partition.h"
#include "nvs.h"
#include "nvs_flash.h"
#include <cstdio>
#include <cstring>
#include <vector>

namespace esphome {
namespace partition_manager {

static const char *const TAG = "partition";

// Shared with nvs_secrets (and write-nvs-secrets.sh): both partitions read and
// write this namespace, which is what lets bootstrap and production publish each
// other's image hash.
static const char *const NVS_NAMESPACE = "iotstack";

namespace {

// Per-slot NVS keys. The hash is the 8-hex ESPHome config_hash of the image in
// that slot; the token identifies WHICH image the hash was taken from, so a slot
// that has since been re-flashed is detected and re-scanned instead of reporting
// a stale hash. Keys stay under the 15-char NVS limit.
struct SlotKeys {
  const char *hash;
  const char *token;
};
constexpr SlotKeys BOOTSTRAP_KEYS{"img_hash_bs", "img_tok_bs"};
constexpr SlotKeys PRODUCTION_KEYS{"img_hash_prod", "img_tok_prod"};

// ESPHome config hash and build-time string are in the first RODATA segment
// (~107 KB on ESP32-S3). Cap reads to 128 KB so they fit in internal SRAM
// without requiring PSRAM, which may not be available on all devices.
static const size_t MAX_SCAN_BYTES = 128 * 1024;

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

  size_t scan_size = std::min((size_t) part->size, MAX_SCAN_BYTES);
  std::vector<uint8_t> image(scan_size);
  if (esp_partition_read(part, 0, image.data(), scan_size) != ESP_OK)
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

// Identity of the image actually sitting in a slot, independent of its config
// hash: the ELF SHA-256 recorded in the app descriptor. Reading it is a header
// read (no 128KB scan), so it is cheap enough to check on every boot.
std::string image_token_(const esp_partition_t *part) {
  if (part == nullptr)
    return "";
  esp_app_desc_t desc;
  if (esp_ota_get_partition_description(part, &desc) != ESP_OK)
    return "";
  char buf[17] = {};
  for (int i = 0; i < 8; i++)
    snprintf(buf + i * 2, 3, "%02x", desc.app_elf_sha256[i]);
  return std::string(buf);
}

std::string nvs_read_(nvs_handle_t handle, const char *key) {
  size_t len = 0;
  if (nvs_get_str(handle, key, nullptr, &len) != ESP_OK || len == 0 || len > 64)
    return "";
  std::vector<char> buf(len);
  if (nvs_get_str(handle, key, buf.data(), &len) != ESP_OK)
    return "";
  return std::string(buf.data());
}

// Write only on change: NVS is flash, and this runs on every boot.
bool nvs_write_if_changed_(nvs_handle_t handle, const char *key, const std::string &value) {
  if (value.empty())
    return false;
  if (nvs_read_(handle, key) == value)
    return false;
  return nvs_set_str(handle, key, value.c_str()) == ESP_OK;
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

  size_t run_scan = std::min((size_t) running->size, MAX_SCAN_BYTES);
  size_t alt_scan = std::min((size_t) alt->size, MAX_SCAN_BYTES);
  std::vector<uint8_t> running_image(run_scan);
  std::vector<uint8_t> alt_image(alt_scan);
  if (esp_partition_read(running, 0, running_image.data(), run_scan) != ESP_OK)
    return false;
  esp_app_desc_t alt_desc;
  if (esp_ota_get_partition_description(alt, &alt_desc) != ESP_OK)
    return false;
  if (esp_partition_read(alt, 0, alt_image.data(), alt_scan) != ESP_OK)
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
  const bool on_bootstrap = running != nullptr && running->subtype == ESP_PARTITION_SUBTYPE_APP_OTA_0;

  const SlotKeys &running_keys = on_bootstrap ? BOOTSTRAP_KEYS : PRODUCTION_KEYS;
  const SlotKeys &alt_keys = on_bootstrap ? PRODUCTION_KEYS : BOOTSTRAP_KEYS;

  char running_buf[9] = {};
  format_hash_(running_hash, running_buf, sizeof(running_buf));
  std::string running_image_hash(running_buf);
  std::string alt_image_hash;

  esp_err_t nvs_err = nvs_flash_init();
  if (nvs_err == ESP_ERR_NVS_NO_FREE_PAGES || nvs_err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
    nvs_flash_erase();
    nvs_err = nvs_flash_init();
  }

  nvs_handle_t handle = 0;
  const bool nvs_ok = nvs_err == ESP_OK && nvs_open(NVS_NAMESPACE, NVS_READWRITE, &handle) == ESP_OK;
  if (!nvs_ok)
    ESP_LOGW(TAG, "NVS namespace '%s' unavailable; image hashes are not persisted", NVS_NAMESPACE);

  // The running slot is authoritative about itself: publish its hash, tagged with
  // the identity of the image that produced it, so the other partition can trust
  // it later without re-deriving it.
  const std::string running_token = image_token_(running);
  bool dirty = false;
  if (nvs_ok) {
    dirty |= nvs_write_if_changed_(handle, running_keys.hash, running_image_hash);
    dirty |= nvs_write_if_changed_(handle, running_keys.token, running_token);
  }

  // The other slot cannot speak for itself while this one is running. Trust the
  // hash it left in NVS only while the image behind it is unchanged; a re-flashed
  // slot fails the token check and is re-scanned (and the scan result cached, so
  // the expensive path runs at most once per image).
  const std::string alt_token = image_token_(alt);
  if (alt_token.empty()) {
    ESP_LOGD(TAG, "No valid image in the other slot; its hash is unknown");
  } else {
    std::string cached_hash;
    if (nvs_ok && nvs_read_(handle, alt_keys.token) == alt_token)
      cached_hash = nvs_read_(handle, alt_keys.hash);

    if (!cached_hash.empty()) {
      alt_image_hash = cached_hash;
      ESP_LOGD(TAG, "Other slot hash from NVS: %s", alt_image_hash.c_str());
    } else {
      uint32_t alt_hash = 0;
      if (read_config_hash_with_calibration_(running, alt, running_hash, &alt_hash)) {
        char alt_buf[9] = {};
        if (format_hash_(alt_hash, alt_buf, sizeof(alt_buf)))
          alt_image_hash = alt_buf;
      }
      if (alt_image_hash.empty()) {
        ESP_LOGW(TAG, "Could not determine the other slot's config hash");
      } else if (nvs_ok) {
        ESP_LOGD(TAG, "Other slot hash recovered by scan: %s (caching)", alt_image_hash.c_str());
        dirty |= nvs_write_if_changed_(handle, alt_keys.hash, alt_image_hash);
        dirty |= nvs_write_if_changed_(handle, alt_keys.token, alt_token);
      }
    }
  }

  if (nvs_ok) {
    if (dirty)
      nvs_commit(handle);
    nvs_close(handle);
  }

  bootstrap_image_hash_ = on_bootstrap ? running_image_hash : alt_image_hash;
  production_image_hash_ = on_bootstrap ? alt_image_hash : running_image_hash;

  ESP_LOGI(TAG, "Image hashes: bootstrap=%s production=%s (running: %s)",
           bootstrap_image_hash_.empty() ? "-" : bootstrap_image_hash_.c_str(),
           production_image_hash_.empty() ? "-" : production_image_hash_.c_str(),
           on_bootstrap ? "bootstrap" : "production");
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