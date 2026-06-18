#pragma once

#ifdef USE_ESP32

#include "esphome/components/display/display_buffer.h"
#include "esphome/core/automation.h"
#include "esphome/core/component.h"
#include "esphome/core/hal.h"
#include "esphome/core/log.h"
#include "hub75.h"

namespace esphome {
namespace matrix_hub75 {

using esphome::display::ColorBitness;
using esphome::display::ColorOrder;

struct MatrixHub75YamlConfig {
  Hub75Pins pins;
  uint16_t panel_width{64};
  uint16_t panel_height{32};
  uint8_t max_layout_cols{2};
  uint8_t default_layout_cols{1};
  Hub75ScanWiring scan_wiring{Hub75ScanWiring::STANDARD_TWO_SCAN};
  Hub75ShiftDriver shift_driver{Hub75ShiftDriver::GENERIC};
  Hub75PanelLayout layout{Hub75PanelLayout::HORIZONTAL};
  Hub75Rotation rotation{Hub75Rotation::ROTATE_0};
  Hub75ClockSpeed output_clock_speed{Hub75ClockSpeed::HZ_20M};
  int min_refresh_rate{60};
  int latch_blanking{1};
  bool double_buffer{false};
  bool clk_phase_inverted{false};
  uint8_t brightness{128};
};

class MatrixHub75Display : public display::Display {
 public:
  explicit MatrixHub75Display(const MatrixHub75YamlConfig &yaml_config);

  void setup() override;
  void dump_config() override;
  float get_setup_priority() const override { return setup_priority::PROCESSOR; }

  void update() override;
  display::DisplayType get_display_type() override { return display::DisplayType::DISPLAY_TYPE_COLOR; }
  void fill(Color color) override;
  void draw_pixel_at(int x, int y, Color color) override;
  void draw_pixels_at(int x_start, int y_start, int w, int h, const uint8_t *ptr, display::ColorOrder order,
                      ColorBitness bitness, bool big_endian, int x_offset, int y_offset, int x_pad) override;

  void set_brightness(uint8_t brightness);

  uint8_t get_layout_cols() const { return this->active_layout_cols_; }
  uint16_t get_panel_width() const { return this->active_panel_width_; }
  uint16_t get_panel_height() const { return this->active_panel_height_; }
  uint16_t get_display_width() const { return this->active_panel_width_ * this->active_layout_cols_; }
  uint16_t get_display_height() const { return this->active_panel_height_; }

 protected:
  int get_width_internal() override { return this->driver_ != nullptr ? this->driver_->get_width() : 0; }
  int get_height_internal() override { return this->driver_ != nullptr ? this->driver_->get_height() : 0; }

  bool read_layout_from_nvs_();
  Hub75Config build_hub75_config_() const;

  MatrixHub75YamlConfig yaml_config_;
  Hub75Config hub75_config_{};
  Hub75Driver *driver_{nullptr};

  uint8_t active_layout_cols_{1};
  uint16_t active_panel_width_{64};
  uint16_t active_panel_height_{32};

  uint8_t brightness_{128};
  bool enabled_{false};
};

template<typename... Ts> class SetBrightnessAction : public Action<Ts...>, public Parented<MatrixHub75Display> {
 public:
  TEMPLATABLE_VALUE(uint8_t, brightness)

  void play(const Ts &...x) override { this->parent_->set_brightness(this->brightness_.value(x...)); }
};

}  // namespace matrix_hub75
}  // namespace esphome

#endif