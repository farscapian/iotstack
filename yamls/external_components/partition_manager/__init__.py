import esphome.codegen as cg
import esphome.config_validation as cv
from esphome.const import CONF_ID

CODEOWNERS = ["@iotstack"]
DEPENDENCIES = []

# Bootstrap-only (see partition_manager_bootstrap.yaml): don't let a device
# "park" in bootstrap indefinitely. Default "0s" (disabled) so production
# builds -- which share this same schema -- are unaffected unless they opt in.
CONF_AUTO_PROMOTE_TIMEOUT = "auto_promote_timeout"

partition_manager_ns = cg.esphome_ns.namespace("partition_manager")
PartitionManager = partition_manager_ns.class_("PartitionManager", cg.Component)

CONFIG_SCHEMA = cv.COMPONENT_SCHEMA.extend(
    {
        cv.GenerateID(): cv.declare_id(PartitionManager),
        cv.Optional(
            CONF_AUTO_PROMOTE_TIMEOUT, default="0s"
        ): cv.positive_time_period_milliseconds,
    }
)


async def to_code(config):
    var = cg.new_Pvariable(config[CONF_ID])
    await cg.register_component(var, config)
    cg.add(
        var.set_auto_promote_timeout(config[CONF_AUTO_PROMOTE_TIMEOUT].total_milliseconds)
    )
