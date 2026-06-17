#pragma once

#include "esphome/core/component.h"
#include <cstdint>

namespace esphome {
namespace partition_manager {

// Centralizes the boot-partition logic shared by every device:
//  - short press of the boot button  -> graceful restart (stays on same slot)
//  - hold 3s+                         -> toggle to other OTA slot + immediate reboot
//  - toggle_boot_partition()          -> validate target, switch, and reboot (also
//                                        callable from a template button / HA)
class PartitionManager : public Component {
 public:
  void handle_button_press();
  void handle_button_release();
  void loop() override;
  void toggle_boot_partition();

  // Set the boot slot to failsafe (ota_0) and reboot. Used by the
  // switch_to_failsafe API service so `iotstack update` can move a running
  // production device into failsafe before OTA (OTA never writes the running
  // partition, so updating from failsafe always targets production).
  void boot_failsafe();

 protected:
  uint32_t press_time_{0};
  bool button_held_{false};
  bool long_press_triggered_{false};
};

}  // namespace partition_manager
}  // namespace esphome
