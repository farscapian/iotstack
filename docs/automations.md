# Home Assistant Automations (`automations/`)

Status: automations themselves are usable today (import/paste into HA
manually); automatic application at provision time is DESIGN / NOT
IMPLEMENTED.

`automations/` at the repo root holds Home Assistant automations that are
generic across the fleet rather than tied to one device instance -- the
intent is that when a role gets provisioned (see [features.md](features.md)
"Home Assistant Integration"), a relevant automation from here gets applied
to it. That provisioning hook does not exist yet: `ha_websocket.py` today
only manages device/entity naming and the mmwave composite helpers (see
features.md items 6-7), not automation config. For now, apply an automation
from this directory by hand via the HA UI.

Two subpaths:

- `automations/blueprints/` -- parameterized `automation_type: automation`
  blueprints. One blueprint backs many device instances (e.g. one per
  matrixdisplay), each filled in with its own inputs (target entity,
  watched domains, ...).
- `automations/plain/` -- static automation YAML with `REPLACE_...`
  placeholders, for a single fixed instance pasted directly into
  `automations.yaml` or a `packages/` file instead of managed as a
  blueprint.

See `automations/README.md` for the up-to-date list of what's there.

## activity_to_matrixdisplay

Mirrors HA's Activity panel onto a matrixdisplay's "Display Text" entity
(`text.matrix_display_<mac>_display_text`, see [devices.md](devices.md)
Matrix Display): triggers on `state_changed` events, filters to a
configurable list of domains (default `binary_sensor`, `device_tracker` --
occupancy/motion and presence, matching the Activity panel's most common
entries), and writes the most recent match to the display via
`text.set_value`.

Notes:
- Only the single latest event is ever shown -- a matrixdisplay has one
  Display Text entity and no scrollback, unlike the Activity panel's list.
  It is a live ticker, not a log.
- Filters out the display's own entity and any `exclude_entities` to avoid
  self-triggering feedback and noisy sources.
- Skips `unknown`/`unavailable` states and no-op state repeats (HA's
  `state_changed` event still fires when only an attribute changes; the
  condition requires `old_state.state != new_state.state`).
- `message_template` is a Jinja template over `trigger.event.data`
  (`new_state`/`old_state`/`entity_id`) -- keep it short, matrixdisplay text
  entities are capped at 255 chars (see matrixdisplay.yaml's "Styles" box
  comment) and the panel itself shows only a handful of characters at once.
- Does not attempt to reproduce the Activity panel's exact wording (e.g.
  binary_sensor device_class "Detected"/"Clear" labels) -- that mapping
  lives in HA's own translations per device_class and would need to be
  duplicated per domain. The default template shows the entity name and raw
  state instead, which is domain-agnostic.
