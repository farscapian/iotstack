"""
NVS Writer Component
Exposes API service to write device-specific secrets to NVS partition.
Allows network-based secret rotation without firmware updates.
"""
import esphome.codegen as cg
import esphome.config_validation as cv
from esphome.const import CONF_ID

CODEOWNERS = ["@iotstack"]
DEPENDENCIES = []

nvs_writer_ns = cg.esphome_ns.namespace("nvs_writer")
NVSWriter = nvs_writer_ns.class_("NVSWriter", cg.Component)

CONFIG_SCHEMA = cv.Schema({
    cv.GenerateID(): cv.declare_id(NVSWriter),
}).extend(cv.COMPONENT_SCHEMA)


async def to_code(config):
    var = cg.new_Pvariable(config[CONF_ID])
    await cg.register_component(var, config)
