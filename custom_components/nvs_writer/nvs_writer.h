#pragma once

#include "esphome/core/component.h"
#include "esphome/core/automation.h"
#include <nvs_flash.h>
#include <nvs.h>

namespace esphome {
namespace nvs_writer {

class NVSWriter : public Component {
 public:
  void setup() override;
  void dump_config() override;

  // Write string value to NVS
  void write_string(const std::string& key, const std::string& value);

  // Write multiple key-value pairs
  void write_nvs_data(const std::vector<std::pair<std::string, std::string>>& data);

  // Erase key from NVS
  void erase_key(const std::string& key);

 protected:
  nvs_handle_t nvs_handle_{0};
  const char* nvs_namespace_ = "iotstack";
};

}  // namespace nvs_writer
}  // namespace esphome
