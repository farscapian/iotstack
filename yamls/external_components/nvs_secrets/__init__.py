import esphome.codegen as cg
import esphome.config_validation as cv
from esphome.const import CONF_ID

CODEOWNERS = ["@iotstack"]
DEPENDENCIES = []

nvs_secrets_ns = cg.esphome_ns.namespace("nvs_secrets")
NVSSecrets = nvs_secrets_ns.class_("NVSSecrets", cg.Component)

CONFIG_SCHEMA = cv.COMPONENT_SCHEMA


async def to_code(config):
    var = cg.new_Pvariable(NVSSecrets)
    await cg.register_component(var, config)
