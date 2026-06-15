#pragma once

#include "esphome/core/component.h"
#include "nvs_flash.h"
#include "nvs.h"
#include <string>

namespace esphome {
namespace nvs_secrets {

class NVSSecrets : public Component {
 public:
  float get_setup_priority() const override { return 200.0f; }  // Hardware initialization priority
  void setup() override;
  void dump_config() override;
  void loop() override;

  std::string get_wifi_ssid() const { return wifi_ssid_; }
  std::string get_wifi_password() const { return wifi_password_; }
  std::string get_ota_password() const { return ota_password_; }
  std::string get_api_encryption_key() const { return api_encryption_key_; }
  std::string get_thread_tlv() const { return thread_tlv_; }

 private:
  std::string wifi_ssid_;
  std::string wifi_password_;
  std::string ota_password_;
  std::string api_encryption_key_;
  std::string thread_tlv_;
  bool logged_status_ = false;

  std::string read_nvs_string(const char* key);
  // Apply the Thread operational dataset (hex TLVs) from NVS to the OpenThread
  // stack at runtime. No-op build unless USE_OPENTHREAD is defined.
  void apply_thread_dataset_();
};

}  // namespace nvs_secrets
}  // namespace esphome
