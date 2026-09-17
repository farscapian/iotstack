# automations

Home Assistant automations that are generally applicable across the fleet,
rather than tied to one specific device instance. The idea: when a device
role (matrixdisplay, lightstrip, ...) gets provisioned into Home Assistant,
a relevant automation from here can be applied to it.

Two subpaths, for two different authoring styles:

- `blueprints/` -- parameterized `automation_type: automation` blueprints
  (HA's own reusable-automation mechanism). Import via Settings >
  Automations > Blueprints > Import Blueprint (local file), or drop into
  HA's `config/blueprints/automation/<user>/`, then create one instance per
  device by filling in its inputs (target entity, watched domains, etc).
  One blueprint can back many device instances.
- `plain/` -- static, non-parameterized automation YAML with placeholder
  values (`REPLACE_...`) to hand-edit and paste into `automations.yaml` or a
  `packages/` file. Use this when you want a single fixed instance and don't
  want to manage it as a blueprint.

Applying these automatically at provision time (e.g. from `ha_websocket.py`
during `iotstack flash`/`update`/`reassign`) is not implemented yet -- for
now, apply manually via the HA UI as above. See docs/automations.md.

## Current automations

- **activity_to_matrixdisplay** (`blueprints/`, `plain/`) -- mirrors the
  Home Assistant Activity panel onto a matrixdisplay's "Display Text"
  entity: watches state changes across a configurable list of domains and
  writes the most recent one to the display.
