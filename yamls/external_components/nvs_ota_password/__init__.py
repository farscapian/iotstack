"""
NVS OTA Password Component
Reads OTA password from NVS partition and configures OTA service dynamically.
This allows a single firmware binary with unique OTA passwords per device.
"""
import esphome.codegen as cg
import esphome.config_validation as cv
from esphome.const import CONF_ID

CODEOWNERS = ["@iotstack"]
DEPENDENCIES = []

nvs_ota_password_ns = cg.esphome_ns.namespace("nvs_ota_password")
NVSOtaPassword = nvs_ota_password_ns.class_("NVSOtaPassword", cg.Component)

CONFIG_SCHEMA = cv.COMPONENT_SCHEMA


async def to_code(config):
    var = cg.new_Pvariable(NVSOtaPassword())
    await cg.register_component(var, config)
