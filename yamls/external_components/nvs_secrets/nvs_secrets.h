#pragma once

#include "esphome/core/component.h"
#include "nvs_flash.h"
#include "nvs.h"
#include <string>

namespace esphome {
namespace nvs_secrets {

class NVSSecrets : public Component {
 public:
  float get_setup_priority() const override {
    return setup_priority::BEFORE_CONNECTION;  // After WiFi (250), before API (200)
  }
  void setup() override;
  void dump_config() override;
  void loop() override;

  void set_ota_nvs_key(const std::string &key) { ota_nvs_key_ = key; }
  void set_api_nvs_key(const std::string &key) { api_nvs_key_ = key; }

  std::string get_wifi_ssid() const { return wifi_ssid_; }
  std::string get_wifi_password() const { return wifi_password_; }
  std::string get_ota_password() const { return ota_password_; }
  std::string get_api_encryption_key() const { return api_encryption_key_; }
  std::string get_thread_tlv() const { return thread_tlv_; }

  // Write a subset of NVS secrets without serial access (used by the
  // update_nvs_secrets API service on the failsafe firmware).
  // Empty string for any parameter means "leave that key unchanged".
  // Commits immediately; caller is responsible for triggering a reboot so the
  // new values take effect at the next setup() call.
  void update_secrets(const std::string &wifi_ssid,
                      const std::string &wifi_password,
                      const std::string &ota_password,
                      const std::string &api_key,
                      const std::string &thread_tlv);

 private:
  std::string ota_nvs_key_{"ota_password"};
  std::string api_nvs_key_{};
  std::string wifi_ssid_;
  std::string wifi_password_;
  std::string ota_password_;
  std::string api_encryption_key_;
  std::string thread_tlv_;
  bool logged_status_ = false;

  std::string read_nvs_string(const char* key);
  void write_nvs_string(nvs_handle_t handle, const char* key, const std::string &value);
  // Apply the Thread operational dataset (hex TLVs) from NVS to the OpenThread
  // stack at runtime. No-op build unless USE_OPENTHREAD is defined.
  void apply_thread_dataset_();
  void apply_api_encryption_key_();
};

}  // namespace nvs_secrets
}  // namespace esphome
