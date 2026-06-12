#pragma once

#include "esphome/core/component.h"
#include "esphome/components/wifi/wifi_component.h"
#include "esphome/components/api/api_server.h"
#include "nvs_flash.h"
#include "nvs.h"
#include <string>

namespace esphome {
namespace nvs_secrets {

class NVSSecrets : public Component {
 public:
  void setup() override;
  void dump_config() override;

  std::string get_wifi_ssid() const { return wifi_ssid_; }
  std::string get_wifi_password() const { return wifi_password_; }
  std::string get_ota_password() const { return ota_password_; }
  std::string get_api_encryption_key() const { return api_encryption_key_; }

 private:
  std::string wifi_ssid_;
  std::string wifi_password_;
  std::string ota_password_;
  std::string api_encryption_key_;

  std::string read_nvs_string(const char* key);
};

}  // namespace nvs_secrets
}  // namespace esphome
