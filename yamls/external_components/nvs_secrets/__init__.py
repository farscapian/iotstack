import esphome.codegen as cg
import esphome.config_validation as cv
from esphome.const import CONF_ID

CODEOWNERS = ["@iotstack"]
DEPENDENCIES = []

nvs_secrets_ns = cg.esphome_ns.namespace("nvs_secrets")
NVSSecrets = nvs_secrets_ns.class_("NVSSecrets", cg.Component)

CONFIG_SCHEMA = cv.COMPONENT_SCHEMA.extend({
    cv.GenerateID(): cv.declare_id(NVSSecrets),
    cv.Optional("ota_nvs_key", default="ota_password"): cv.string,
    cv.Optional("api_nvs_key", default=""): cv.string,
})


async def to_code(config):
    var = cg.new_Pvariable(config[CONF_ID])
    await cg.register_component(var, config)
    cg.add(var.set_ota_nvs_key(config["ota_nvs_key"]))
    cg.add(var.set_api_nvs_key(config["api_nvs_key"]))
