#pragma once

#include "esphome/core/component.h"
#include "esphome/components/ota/ota_component.h"
#include "nvs_flash.h"
#include "nvs.h"
#include <string>

namespace esphome {
namespace nvs_ota_password {

class NVSOtaPassword : public Component {
 public:
  void setup() override;
  void dump_config() override;

 private:
  std::string read_nvs_string(const char* key);
};

}  // namespace nvs_ota_password
}  // namespace esphome
