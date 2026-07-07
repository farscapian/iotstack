#include "matrix_hub75.h"
#include "esphome/core/application.h"

#include <algorithm>
#include <cinttypes>

#include "nvs_flash.h"

#ifdef USE_ESP32

namespace esphome {
namespace matrix_hub75 {

static const char *const TAG = "matrix_hub75";
static const char *const NVS_NAMESPACE = "iotstack";

MatrixHub75Display::MatrixHub75Display(const MatrixHub75YamlConfig &yaml_config) : yaml_config_(yaml_config) {
  this->brightness_ = yaml_config.brightness;
  this->enabled_ = (yaml_config.brightness > 0);
}

bool MatrixHub75Display::read_layout_from_nvs_() {
  esp_err_t err = nvs_flash_init();
  if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
    nvs_flash_erase();
    err = nvs_flash_init();
  }
  if (err != ESP_OK) {
    ESP_LOGW(TAG, "NVS init failed (%s); using YAML defaults", esp_err_to_name(err));
    return false;
  }

  nvs_handle_t handle;
  err = nvs_open(NVS_NAMESPACE, NVS_READONLY, &handle);
  if (err != ESP_OK) {
    ESP_LOGI(TAG, "No iotstack NVS namespace yet (%s); using YAML defaults", esp_err_to_name(err));
    return false;
  }

  uint8_t cols = this->yaml_config_.default_layout_cols;
  uint8_t rows = this->yaml_config_.default_layout_rows;
  uint16_t panel_w = this->yaml_config_.panel_width;
  uint16_t panel_h = this->yaml_config_.panel_height;
  bool found = false;

  if (nvs_get_u8(handle, "matrix_cols", &cols) == ESP_OK) {
    found = true;
  }
  if (nvs_get_u8(handle, "matrix_rows", &rows) == ESP_OK) {
    found = true;
  }
  if (nvs_get_u16(handle, "matrix_panel_w", &panel_w) == ESP_OK) {
    found = true;
  }
  if (nvs_get_u16(handle, "matrix_panel_h", &panel_h) == ESP_OK) {
    found = true;
  }

  nvs_close(handle);

  cols = std::max<uint8_t>(1, std::min<uint8_t>(cols, this->yaml_config_.max_layout_cols));
  rows = std::max<uint8_t>(1, std::min<uint8_t>(rows, this->yaml_config_.max_layout_rows));
  if (panel_w < 8 || panel_w > 256) {
    ESP_LOGW(TAG, "Invalid NVS matrix_panel_w=%u; using YAML default %u", panel_w, this->yaml_config_.panel_width);
    panel_w = this->yaml_config_.panel_width;
  }
  if (panel_h < 8 || panel_h > 128) {
    ESP_LOGW(TAG, "Invalid NVS matrix_panel_h=%u; using YAML default %u", panel_h, this->yaml_config_.panel_height);
    panel_h = this->yaml_config_.panel_height;
  }

  this->active_layout_cols_ = cols;
  this->active_layout_rows_ = rows;
  this->active_panel_width_ = panel_w;
  this->active_panel_height_ = panel_h;

  if (found) {
    ESP_LOGI(TAG, "Matrix layout from NVS: %ux%u panel(s) of %ux%u (%ux%u virtual)",
             this->active_layout_cols_, this->active_layout_rows_, this->active_panel_width_,
             this->active_panel_height_, this->get_display_width(), this->get_display_height());
  } else {
    ESP_LOGI(TAG, "Matrix layout defaults: %ux%u panel(s) of %ux%u (%ux%u virtual)",
             this->active_layout_cols_, this->active_layout_rows_, this->active_panel_width_,
             this->active_panel_height_, this->get_display_width(), this->get_display_height());
  }

  return found;
}

Hub75Config MatrixHub75Display::build_hub75_config_() const {
  Hub75Config cfg = {};
  cfg.panel_width = this->active_panel_width_;
  cfg.panel_height = this->active_panel_height_;
  cfg.scan_wiring = this->yaml_config_.scan_wiring;
  cfg.shift_driver = this->yaml_config_.shift_driver;
  cfg.layout_rows = this->active_layout_rows_;
  cfg.layout_cols = this->active_layout_cols_;
  cfg.layout = this->yaml_config_.layout;
  cfg.rotation = this->yaml_config_.rotation;
  cfg.pins = this->yaml_config_.pins;
  cfg.output_clock_speed = this->yaml_config_.output_clock_speed;
  cfg.min_refresh_rate = this->yaml_config_.min_refresh_rate;
  cfg.latch_blanking = this->yaml_config_.latch_blanking;
  cfg.double_buffer = this->yaml_config_.double_buffer;
  cfg.clk_phase_inverted = this->yaml_config_.clk_phase_inverted;
  cfg.brightness = this->yaml_config_.brightness;
  return cfg;
}

void MatrixHub75Display::setup() {
  ESP_LOGCONFIG(TAG, "Setting up MatrixHub75Display...");

  this->read_layout_from_nvs_();
  this->hub75_config_ = this->build_hub75_config_();

  this->driver_ = new Hub75Driver(this->hub75_config_);
  if (!this->driver_->begin()) {
    ESP_LOGE(TAG, "Failed to initialize HUB75 driver!");
    return;
  }

  this->enabled_ = true;
}

void MatrixHub75Display::dump_config() {
  LOG_DISPLAY("", "MatrixHub75", this);

  ESP_LOGCONFIG(TAG,
                "  Panel: %ux%u pixels\n"
                "  Layout: %ux%u panels (cols x rows; from NVS or defaults)\n"
                "  Virtual Display: %ux%u pixels",
                this->active_panel_width_, this->active_panel_height_, this->active_layout_cols_,
                this->active_layout_rows_, this->get_display_width(), this->get_display_height());

  ESP_LOGCONFIG(TAG,
                "  Scan Wiring: %d\n"
                "  Shift Driver: %d",
                static_cast<int>(this->hub75_config_.scan_wiring), static_cast<int>(this->hub75_config_.shift_driver));

  ESP_LOGCONFIG(TAG,
                "  Pins: R1:%i, G1:%i, B1:%i, R2:%i, G2:%i, B2:%i\n"
                "  Pins: A:%i, B:%i, C:%i, D:%i, E:%i\n"
                "  Pins: LAT:%i, OE:%i, CLK:%i",
                this->hub75_config_.pins.r1, this->hub75_config_.pins.g1, this->hub75_config_.pins.b1,
                this->hub75_config_.pins.r2, this->hub75_config_.pins.g2, this->hub75_config_.pins.b2,
                this->hub75_config_.pins.a, this->hub75_config_.pins.b, this->hub75_config_.pins.c,
                this->hub75_config_.pins.d, this->hub75_config_.pins.e, this->hub75_config_.pins.lat,
                this->hub75_config_.pins.oe, this->hub75_config_.pins.clk);

  ESP_LOGCONFIG(TAG,
                "  Clock Speed: %" PRIu32 " MHz\n"
                "  Latch Blanking: %i\n"
                "  Clock Phase: %s\n"
                "  Min Refresh Rate: %i Hz\n"
                "  Double Buffer: %s",
                static_cast<uint32_t>(this->hub75_config_.output_clock_speed) / 1000000, this->hub75_config_.latch_blanking,
                TRUEFALSE(this->hub75_config_.clk_phase_inverted), this->hub75_config_.min_refresh_rate,
                YESNO(this->hub75_config_.double_buffer));
}

void MatrixHub75Display::update() {
  if (!this->driver_) [[unlikely]]
    return;
  if (!this->enabled_) [[unlikely]]
    return;

  this->do_update_();

  if (this->hub75_config_.double_buffer) {
    this->driver_->flip_buffer();
  }
}

void MatrixHub75Display::fill(Color color) {
  if (!this->driver_) [[unlikely]]
    return;
  if (!this->enabled_) [[unlikely]]
    return;

  display::Rect fill_rect(0, 0, this->get_width_internal(), this->get_height_internal());
  display::Rect clip = this->get_clipping();
  if (clip.is_set()) {
    fill_rect.shrink(clip);
    if (!fill_rect.is_set())
      return;
  }

  if (!color.is_on() && fill_rect.x == 0 && fill_rect.y == 0 && fill_rect.w == this->get_width_internal() &&
      fill_rect.h == this->get_height_internal()) {
    this->driver_->clear();
    return;
  }

  this->driver_->fill(fill_rect.x, fill_rect.y, fill_rect.w, fill_rect.h, color.r, color.g, color.b);
}

void HOT MatrixHub75Display::draw_pixel_at(int x, int y, Color color) {
  if (!this->driver_) [[unlikely]]
    return;
  if (!this->enabled_) [[unlikely]]
    return;

  if (x >= this->get_width_internal() || x < 0 || y >= this->get_height_internal() || y < 0) [[unlikely]]
    return;

  if (!this->get_clipping().inside(x, y))
    return;

  this->driver_->set_pixel(x, y, color.r, color.g, color.b);
  App.feed_wdt();
}

void HOT MatrixHub75Display::draw_pixels_at(int x_start, int y_start, int w, int h, const uint8_t *ptr,
                                            display::ColorOrder order, ColorBitness bitness, bool big_endian,
                                            int x_offset, int y_offset, int x_pad) {
  if (!this->driver_) [[unlikely]]
    return;
  if (!this->enabled_) [[unlikely]]
    return;

  Hub75PixelFormat format;
  Hub75ColorOrder color_order = Hub75ColorOrder::RGB;
  int bytes_per_pixel;

  if (bitness == ColorBitness::COLOR_BITNESS_565) {
    format = Hub75PixelFormat::RGB565;
    bytes_per_pixel = 2;
  } else if (bitness == ColorBitness::COLOR_BITNESS_888) {
#ifdef USE_LVGL
#if LV_COLOR_DEPTH == 32
    format = Hub75PixelFormat::RGB888_32;
    bytes_per_pixel = 4;
    color_order = (order == ColorOrder::COLOR_ORDER_RGB) ? Hub75ColorOrder::RGB : Hub75ColorOrder::BGR;
#elif LV_COLOR_DEPTH == 24
    format = Hub75PixelFormat::RGB888;
    bytes_per_pixel = 3;
#else
    ESP_LOGE(TAG, "Unsupported LV_COLOR_DEPTH: %d", LV_COLOR_DEPTH);
    return;
#endif
#else
    format = Hub75PixelFormat::RGB888;
    bytes_per_pixel = 3;
    color_order = (order == ColorOrder::COLOR_ORDER_RGB) ? Hub75ColorOrder::RGB : Hub75ColorOrder::BGR;
#endif
  } else {
    ESP_LOGE(TAG, "Unsupported bitness: %d", static_cast<int>(bitness));
    return;
  }

  const int stride_px = x_offset + w + x_pad;
  const bool is_packed = (x_offset == 0 && x_pad == 0 && y_offset == 0);

  if (is_packed) {
    this->driver_->draw_pixels(x_start, y_start, w, h, ptr, format, color_order, big_endian);
  } else {
    for (int yy = 0; yy < h; ++yy) {
      const size_t row_offset = ((y_offset + yy) * stride_px + x_offset) * bytes_per_pixel;
      const uint8_t *row_ptr = ptr + row_offset;
      this->driver_->draw_pixels(x_start, y_start + yy, w, 1, row_ptr, format, color_order, big_endian);
    }
  }
}

void MatrixHub75Display::set_brightness(uint8_t brightness) {
  this->brightness_ = brightness;
  this->enabled_ = (brightness > 0);
  if (this->driver_ != nullptr) {
    this->driver_->set_brightness(brightness);
  }
}

}  // namespace matrix_hub75
}  // namespace esphome

#endif