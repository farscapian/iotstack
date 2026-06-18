import logging

from esphome import automation, pins
import esphome.codegen as cg
from esphome.components import display
from esphome.components.esp32 import add_idf_component
import esphome.config_validation as cv
from esphome.const import (
    CONF_AUTO_CLEAR_ENABLED,
    CONF_BIT_DEPTH,
    CONF_BRIGHTNESS,
    CONF_CLK_PIN,
    CONF_GAMMA_CORRECT,
    CONF_ID,
    CONF_LAMBDA,
    CONF_OE_PIN,
    CONF_ROTATION,
    CONF_UPDATE_INTERVAL,
)
from esphome.core import EnumValue
from esphome.cpp_generator import MockObj, TemplateArgsType
import esphome.final_validate as fv
from esphome.helpers import add_class_to_obj
from esphome.types import ConfigType

from . import matrix_hub75_ns

_LOGGER = logging.getLogger(__name__)

DEPENDENCIES = ["esp32"]
CODEOWNERS = ["@iotstack"]

CONF_PANEL_WIDTH = "panel_width"
CONF_PANEL_HEIGHT = "panel_height"
CONF_MAX_LAYOUT_COLS = "max_layout_cols"
CONF_DEFAULT_LAYOUT_COLS = "default_layout_cols"
CONF_SCAN_WIRING = "scan_wiring"
CONF_SHIFT_DRIVER = "shift_driver"
CONF_LAYOUT = "layout"
CONF_R1_PIN = "r1_pin"
CONF_G1_PIN = "g1_pin"
CONF_B1_PIN = "b1_pin"
CONF_R2_PIN = "r2_pin"
CONF_G2_PIN = "g2_pin"
CONF_B2_PIN = "b2_pin"
CONF_A_PIN = "a_pin"
CONF_B_PIN = "b_pin"
CONF_C_PIN = "c_pin"
CONF_D_PIN = "d_pin"
CONF_E_PIN = "e_pin"
CONF_LAT_PIN = "lat_pin"
CONF_CLOCK_SPEED = "clock_speed"
CONF_LATCH_BLANKING = "latch_blanking"
CONF_CLOCK_PHASE = "clock_phase"
CONF_DOUBLE_BUFFER = "double_buffer"
CONF_MIN_REFRESH_RATE = "min_refresh_rate"

NEVER = 4294967295

PIN_MAPPING = {
    CONF_R1_PIN: "r1",
    CONF_G1_PIN: "g1",
    CONF_B1_PIN: "b1",
    CONF_R2_PIN: "r2",
    CONF_G2_PIN: "g2",
    CONF_B2_PIN: "b2",
    CONF_A_PIN: "a",
    CONF_B_PIN: "b",
    CONF_C_PIN: "c",
    CONF_D_PIN: "d",
    CONF_E_PIN: "e",
    CONF_LAT_PIN: "lat",
    CONF_OE_PIN: "oe",
    CONF_CLK_PIN: "clk",
}

REQUIRED_PINS = [key for key in PIN_MAPPING if key != CONF_E_PIN]

Hub75ShiftDriver = cg.global_ns.enum("Hub75ShiftDriver", is_class=True)
SHIFT_DRIVERS = {
    "GENERIC": Hub75ShiftDriver.GENERIC,
    "FM6126A": Hub75ShiftDriver.FM6126A,
    "ICN2038S": Hub75ShiftDriver.ICN2038S,
    "FM6124": Hub75ShiftDriver.FM6124,
    "MBI5124": Hub75ShiftDriver.MBI5124,
    "DP3246": Hub75ShiftDriver.DP3246,
}

Hub75PanelLayout = cg.global_ns.enum("Hub75PanelLayout", is_class=True)
PANEL_LAYOUTS = {
    "HORIZONTAL": Hub75PanelLayout.HORIZONTAL,
}

Hub75ScanWiring = cg.global_ns.enum("Hub75ScanWiring", is_class=True)
SCAN_WIRINGS = {
    "STANDARD_TWO_SCAN": Hub75ScanWiring.STANDARD_TWO_SCAN,
}

Hub75ClockSpeed = cg.global_ns.enum("Hub75ClockSpeed", is_class=True)
CLOCK_SPEEDS = {
    "8MHZ": Hub75ClockSpeed.HZ_8M,
    "10MHZ": Hub75ClockSpeed.HZ_10M,
    "16MHZ": Hub75ClockSpeed.HZ_16M,
    "20MHZ": Hub75ClockSpeed.HZ_20M,
}

Hub75Rotation = cg.global_ns.enum("Hub75Rotation", is_class=True)
ROTATIONS = {
    0: Hub75Rotation.ROTATE_0,
    90: Hub75Rotation.ROTATE_90,
    180: Hub75Rotation.ROTATE_180,
    270: Hub75Rotation.ROTATE_270,
}

MatrixHub75YamlConfig = matrix_hub75_ns.struct("MatrixHub75YamlConfig")
MatrixHub75Display = matrix_hub75_ns.class_(
    "MatrixHub75Display", cg.PollingComponent, display.Display
)
Hub75Pins = cg.global_ns.struct("Hub75Pins")
SetBrightnessAction = matrix_hub75_ns.class_("SetBrightnessAction", automation.Action)


def _validate_required_pins(config: ConfigType) -> ConfigType:
    errs = [
        cv.Invalid(f"Required pin '{pin_name}' is missing.", path=[pin_name])
        for pin_name in REQUIRED_PINS
        if pin_name not in config
    ]
    if errs:
        raise cv.MultipleInvalid(errs)
    return config


def _validate_config(config: ConfigType) -> ConfigType:
    if config.get(CONF_SHIFT_DRIVER, "GENERIC") == "MBI5124" and not config.get(
        CONF_CLOCK_PHASE, False
    ):
        raise cv.Invalid(
            "MBI5124 shift driver requires 'clock_phase: true' to be set",
            path=[CONF_CLOCK_PHASE],
        )
    if config.get(CONF_DEFAULT_LAYOUT_COLS, 1) > config.get(CONF_MAX_LAYOUT_COLS, 2):
        raise cv.Invalid(
            "default_layout_cols cannot exceed max_layout_cols",
            path=[CONF_DEFAULT_LAYOUT_COLS],
        )
    return config


def _final_validate(config: ConfigType) -> ConfigType:
    from esphome.components.lvgl import DOMAIN as LVGL_DOMAIN

    full_config = fv.full_config.get()
    errs: list[cv.Invalid] = []

    if LVGL_DOMAIN in full_config:
        update_interval = config.get(CONF_UPDATE_INTERVAL)
        if update_interval is not None:
            interval_ms = (
                update_interval
                if isinstance(update_interval, int)
                else update_interval.total_milliseconds
            )
            if interval_ms != NEVER:
                errs.append(
                    cv.Invalid(
                        "Matrix HUB75 display with LVGL must have 'update_interval: never'.",
                        path=[CONF_UPDATE_INTERVAL],
                    )
                )
        if config[CONF_AUTO_CLEAR_ENABLED] is not False:
            errs.append(
                cv.Invalid(
                    "Matrix HUB75 display with LVGL must have 'auto_clear_enabled: false'.",
                    path=[CONF_AUTO_CLEAR_ENABLED],
                )
            )
        if config.get(CONF_DOUBLE_BUFFER, False) is not False:
            errs.append(
                cv.Invalid(
                    "Matrix HUB75 display with LVGL must have 'double_buffer: false'.",
                    path=[CONF_DOUBLE_BUFFER],
                )
            )

    if errs:
        raise cv.MultipleInvalid(errs)
    return config


FINAL_VALIDATE_SCHEMA = cv.Schema(_final_validate)

CONFIG_SCHEMA = cv.All(
    _validate_required_pins,
    display.FULL_DISPLAY_SCHEMA.extend(
        {
            cv.GenerateID(): cv.declare_id(MatrixHub75Display),
            cv.Optional(CONF_ROTATION): cv.enum(ROTATIONS, int=True),
            cv.Required(CONF_PANEL_WIDTH): cv.positive_int,
            cv.Required(CONF_PANEL_HEIGHT): cv.positive_int,
            cv.Optional(CONF_MAX_LAYOUT_COLS, default=2): cv.int_range(min=1, max=2),
            cv.Optional(CONF_DEFAULT_LAYOUT_COLS, default=1): cv.int_range(
                min=1, max=2
            ),
            cv.Optional(CONF_LAYOUT): cv.enum(PANEL_LAYOUTS, upper=True, space="_"),
            cv.Optional(CONF_SCAN_WIRING): cv.enum(SCAN_WIRINGS, upper=True),
            cv.Optional(CONF_SHIFT_DRIVER): cv.enum(SHIFT_DRIVERS, upper=True),
            cv.Optional(CONF_DOUBLE_BUFFER): cv.boolean,
            cv.Optional(CONF_BRIGHTNESS): cv.int_range(min=0, max=255),
            cv.Optional(CONF_BIT_DEPTH): cv.int_range(min=4, max=12),
            cv.Optional(CONF_GAMMA_CORRECT): cv.enum(
                {"LINEAR": 0, "CIE1931": 1, "GAMMA_2_2": 2}, upper=True
            ),
            cv.Optional(CONF_MIN_REFRESH_RATE): cv.int_range(min=40, max=200),
            cv.Optional(CONF_R1_PIN): pins.gpio_output_pin_schema,
            cv.Optional(CONF_G1_PIN): pins.gpio_output_pin_schema,
            cv.Optional(CONF_B1_PIN): pins.gpio_output_pin_schema,
            cv.Optional(CONF_R2_PIN): pins.gpio_output_pin_schema,
            cv.Optional(CONF_G2_PIN): pins.gpio_output_pin_schema,
            cv.Optional(CONF_B2_PIN): pins.gpio_output_pin_schema,
            cv.Optional(CONF_A_PIN): pins.gpio_output_pin_schema,
            cv.Optional(CONF_B_PIN): pins.gpio_output_pin_schema,
            cv.Optional(CONF_C_PIN): pins.gpio_output_pin_schema,
            cv.Optional(CONF_D_PIN): pins.gpio_output_pin_schema,
            cv.Optional(CONF_E_PIN): pins.gpio_output_pin_schema,
            cv.Optional(CONF_LAT_PIN): pins.gpio_output_pin_schema,
            cv.Optional(CONF_OE_PIN): pins.gpio_output_pin_schema,
            cv.Optional(CONF_CLK_PIN): pins.gpio_output_pin_schema,
            cv.Optional(CONF_CLOCK_SPEED): cv.enum(CLOCK_SPEEDS, upper=True),
            cv.Optional(CONF_LATCH_BLANKING): cv.positive_int,
            cv.Optional(CONF_CLOCK_PHASE): cv.boolean,
        }
    ),
    _validate_config,
)


DEFAULT_REFRESH_RATE = 60


def _calculate_min_refresh_rate(config: ConfigType) -> int:
    if CONF_MIN_REFRESH_RATE in config:
        return config[CONF_MIN_REFRESH_RATE]
    update_interval = config.get(CONF_UPDATE_INTERVAL)
    if update_interval is None:
        return DEFAULT_REFRESH_RATE
    interval_ms = (
        update_interval
        if isinstance(update_interval, int)
        else update_interval.total_milliseconds
    )
    if interval_ms in (NEVER, 0):
        return DEFAULT_REFRESH_RATE
    return max(40, min(200, int(round(1000 / interval_ms))))


def _build_pins_struct(
    pin_expressions: dict[str, object], e_pin_num: int | cg.RawExpression
) -> cg.StructInitializer:
    def pin_cast(pin):
        return cg.RawExpression(f"static_cast<int8_t>({pin.get_pin()})")

    return cg.StructInitializer(
        Hub75Pins,
        ("r1", pin_cast(pin_expressions["r1"])),
        ("g1", pin_cast(pin_expressions["g1"])),
        ("b1", pin_cast(pin_expressions["b1"])),
        ("r2", pin_cast(pin_expressions["r2"])),
        ("g2", pin_cast(pin_expressions["g2"])),
        ("b2", pin_cast(pin_expressions["b2"])),
        ("a", pin_cast(pin_expressions["a"])),
        ("b", pin_cast(pin_expressions["b"])),
        ("c", pin_cast(pin_expressions["c"])),
        ("d", pin_cast(pin_expressions["d"])),
        ("e", e_pin_num),
        ("lat", pin_cast(pin_expressions["lat"])),
        ("oe", pin_cast(pin_expressions["oe"])),
        ("clk", pin_cast(pin_expressions["clk"])),
    )


async def to_code(config: ConfigType) -> None:
    add_idf_component(name="esphome/esp-hub75", ref="0.3.5")

    if CONF_BIT_DEPTH in config:
        cg.add_build_flag(f"-DHUB75_BIT_DEPTH={config[CONF_BIT_DEPTH]}")
    if CONF_GAMMA_CORRECT in config:
        cg.add_build_flag(f"-DHUB75_GAMMA_MODE={config[CONF_GAMMA_CORRECT].enum_value}")

    pin_expressions = {
        "r1": await cg.gpio_pin_expression(config[CONF_R1_PIN]),
        "g1": await cg.gpio_pin_expression(config[CONF_G1_PIN]),
        "b1": await cg.gpio_pin_expression(config[CONF_B1_PIN]),
        "r2": await cg.gpio_pin_expression(config[CONF_R2_PIN]),
        "g2": await cg.gpio_pin_expression(config[CONF_G2_PIN]),
        "b2": await cg.gpio_pin_expression(config[CONF_B2_PIN]),
        "a": await cg.gpio_pin_expression(config[CONF_A_PIN]),
        "b": await cg.gpio_pin_expression(config[CONF_B_PIN]),
        "c": await cg.gpio_pin_expression(config[CONF_C_PIN]),
        "d": await cg.gpio_pin_expression(config[CONF_D_PIN]),
        "lat": await cg.gpio_pin_expression(config[CONF_LAT_PIN]),
        "oe": await cg.gpio_pin_expression(config[CONF_OE_PIN]),
        "clk": await cg.gpio_pin_expression(config[CONF_CLK_PIN]),
    }

    if CONF_E_PIN in config:
        e_pin = await cg.gpio_pin_expression(config[CONF_E_PIN])
        e_pin_num = cg.RawExpression(f"static_cast<int8_t>({e_pin.get_pin()})")
    else:
        e_pin_num = -1

    min_refresh = _calculate_min_refresh_rate(config)
    pins_struct = _build_pins_struct(pin_expressions, e_pin_num)

    yaml_fields: list[tuple[str, object]] = [
        ("pins", pins_struct),
        ("panel_width", config[CONF_PANEL_WIDTH]),
        ("panel_height", config[CONF_PANEL_HEIGHT]),
        ("max_layout_cols", config[CONF_MAX_LAYOUT_COLS]),
        ("default_layout_cols", config[CONF_DEFAULT_LAYOUT_COLS]),
    ]

    if CONF_SCAN_WIRING in config:
        yaml_fields.append(("scan_wiring", config[CONF_SCAN_WIRING]))
    if CONF_SHIFT_DRIVER in config:
        yaml_fields.append(("shift_driver", config[CONF_SHIFT_DRIVER]))
    if CONF_LAYOUT in config:
        yaml_fields.append(("layout", config[CONF_LAYOUT]))
    if CONF_ROTATION in config:
        yaml_fields.append(("rotation", config[CONF_ROTATION]))
    if CONF_CLOCK_SPEED in config:
        yaml_fields.append(("output_clock_speed", config[CONF_CLOCK_SPEED]))
    yaml_fields.append(("min_refresh_rate", min_refresh))
    if CONF_LATCH_BLANKING in config:
        yaml_fields.append(("latch_blanking", config[CONF_LATCH_BLANKING]))
    if CONF_DOUBLE_BUFFER in config:
        yaml_fields.append(("double_buffer", config[CONF_DOUBLE_BUFFER]))
    if CONF_CLOCK_PHASE in config:
        yaml_fields.append(("clk_phase_inverted", config[CONF_CLOCK_PHASE]))
    if CONF_BRIGHTNESS in config:
        yaml_fields.append(("brightness", config[CONF_BRIGHTNESS]))

    yaml_config = cg.StructInitializer(MatrixHub75YamlConfig, *yaml_fields)

    if CONF_ROTATION in config:
        config[CONF_ROTATION] = 0

    var = cg.new_Pvariable(config[CONF_ID], yaml_config)
    await display.register_display(var, config)

    if CONF_LAMBDA in config:
        lambda_ = await cg.process_lambda(
            config[CONF_LAMBDA], [(display.DisplayRef, "it")], return_type=cg.void
        )
        cg.add(var.set_writer(lambda_))


@automation.register_action(
    "matrix_hub75.set_brightness",
    SetBrightnessAction,
    cv.maybe_simple_value(
        {
            cv.GenerateID(): cv.use_id(MatrixHub75Display),
            cv.Required(CONF_BRIGHTNESS): cv.templatable(cv.int_range(min=0, max=255)),
        },
        key=CONF_BRIGHTNESS,
    ),
    synchronous=True,
)
async def matrix_hub75_set_brightness_to_code(
    config: ConfigType,
    action_id: cg.ID,
    template_arg: TemplateArgsType,
    args: TemplateArgsType,
) -> MockObj:
    var = cg.new_Pvariable(action_id, template_arg)
    await cg.register_parented(var, config[CONF_ID])
    template_ = await cg.templatable(config[CONF_BRIGHTNESS], args, cg.uint8)
    cg.add(var.set_brightness(template_))
    return var