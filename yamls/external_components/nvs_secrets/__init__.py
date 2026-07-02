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
    # NVS key holding THIS image's own API noise PSK, read at boot and applied
    # via set_noise_psk (production: prod_api_key; bootstrap: boot_api_key).
    cv.Optional("api_nvs_key", default=""): cv.string,
    # NVS key that the update_nvs_secrets service writes the incoming api_key
    # payload into (bootstrap provisions production images with prod_api_key).
    # Distinct from api_nvs_key so bootstrap never overwrites its own PSK.
    cv.Optional("update_api_nvs_key", default=""): cv.string,
    # When true, the update_nvs_secrets service refuses to run unless an API
    # noise PSK was successfully applied at boot. Prevents a keyless (e.g.
    # erased) bootstrap device from accepting secrets over a plaintext channel;
    # recovery of such a device is then USB-only (zero-trust LAN).
    cv.Optional("require_api_encryption", default=False): cv.boolean,
})


async def to_code(config):
    var = cg.new_Pvariable(config[CONF_ID])
    await cg.register_component(var, config)
    cg.add(var.set_ota_nvs_key(config["ota_nvs_key"]))
    cg.add(var.set_api_nvs_key(config["api_nvs_key"]))
    cg.add(var.set_update_api_nvs_key(config["update_api_nvs_key"]))
    cg.add(var.set_require_api_encryption(config["require_api_encryption"]))
