#pragma once

#include "esphome/core/component.h"
#include <cstdint>
#include <string>

namespace esphome {
namespace partition_manager {

// Centralizes the boot-partition logic shared by every device:
//  - short press of the boot button  -> graceful restart (stays on same slot)
//  - hold 3s+                         -> toggle to other OTA slot + immediate reboot
//  - toggle_boot_partition()          -> validate target, switch, and reboot (also
//                                        callable from a template button / HA)
class PartitionManager : public Component {
 public:
  void setup() override;
  void handle_button_press();
  void handle_button_release();
  void loop() override;
  void toggle_boot_partition();

  // Set the boot slot to bootstrap (ota_0) and reboot. Used by the
  // switch_to_bootstrap API service so `iotstack update` can move a running
  // production device into bootstrap before OTA (OTA never writes the running
  // partition, so updating from bootstrap always targets production).
  void boot_bootstrap();

  // 8-char lowercase hex ESPHome config_hash values for mDNS TXT records.
  // Both slots are known on either partition: each image records its own hash in
  // the shared "iotstack" NVS namespace, so the running image reads the other
  // slot's hash instead of only being able to describe itself.
  std::string get_bootstrap_image_hash() const { return bootstrap_image_hash_; }
  std::string get_production_image_hash() const { return production_image_hash_; }

 protected:
  uint32_t press_time_{0};
  bool button_held_{false};
  bool long_press_triggered_{false};
  std::string bootstrap_image_hash_;
  std::string production_image_hash_;

  void refresh_image_hashes_();
};

}  // namespace partition_manager
}  // namespace esphome