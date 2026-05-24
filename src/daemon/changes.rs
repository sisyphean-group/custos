use std::collections::BTreeMap;

use tracing::info;

use super::state::DeviceKey;
use crate::{
  device::DeviceState,
  policy::{Action, Decision},
  sysfs::UsbDevice,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum DeviceChangeKind {
  Connected,
  Removed,
  DecisionChanged,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct DeviceChangeEvent {
  pub(super) kind: DeviceChangeKind,
  pub(super) device: DeviceSummary,
  pub(super) action: Action,
  pub(super) previous_action: Option<Action>,
  pub(super) reason: String,
  pub(super) rule: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct DeviceSummary {
  id: u32,
  port_path: String,
  vendor_id: String,
  product_id: String,
  product_name: Option<String>,
  serial: Option<String>,
  is_hub: bool,
}

impl DeviceSummary {
  fn product_name(&self) -> &str {
    optional_str(self.product_name.as_deref())
  }

  fn serial(&self) -> &str {
    optional_str(self.serial.as_deref())
  }
}

impl From<&UsbDevice> for DeviceSummary {
  fn from(device: &UsbDevice) -> Self {
    Self {
      id: device.id,
      port_path: device.port_path.clone(),
      vendor_id: device.vendor_id.clone(),
      product_id: device.product_id.clone(),
      product_name: device.product_name.clone(),
      serial: device.serial.clone(),
      is_hub: device.is_hub,
    }
  }
}

pub(super) fn collect_device_change_events(
  previous_devices: &[DeviceState],
  devices: &[DeviceState],
) -> Vec<DeviceChangeEvent> {
  let previous_by_key: BTreeMap<DeviceKey, &DeviceState> = previous_devices
    .iter()
    .map(|state| (DeviceKey::from(&state.device), state))
    .collect();
  let current_by_key: BTreeMap<DeviceKey, &DeviceState> = devices
    .iter()
    .map(|state| (DeviceKey::from(&state.device), state))
    .collect();
  let mut events = Vec::new();

  for state in devices {
    let key = DeviceKey::from(&state.device);
    let Some(previous_state) = previous_by_key.get(&key).copied() else {
      events.push(device_event(DeviceChangeKind::Connected, state, None));
      continue;
    };

    let previous_action = previous_state.decision.action;
    if previous_action != state.decision.action {
      events.push(device_event(
        DeviceChangeKind::DecisionChanged,
        state,
        Some(previous_action),
      ));
    }
  }

  for state in previous_devices {
    let key = DeviceKey::from(&state.device);
    if !current_by_key.contains_key(&key) {
      events.push(device_event(DeviceChangeKind::Removed, state, None));
    }
  }

  events
}

fn device_event(
  kind: DeviceChangeKind,
  state: &DeviceState,
  previous_action: Option<Action>,
) -> DeviceChangeEvent {
  DeviceChangeEvent {
    kind,
    device: DeviceSummary::from(&state.device),
    action: state.decision.action,
    previous_action,
    reason: state.decision.reason.clone(),
    rule: state.decision.rule.clone(),
  }
}

pub(super) fn log_device_change(event: &DeviceChangeEvent) {
  let action = event.action.as_str();
  let previous_action = event.previous_action.map_or("unknown", Action::as_str);
  let reason = event.reason.as_str();
  let rule = optional_str(event.rule.as_deref());

  match event.kind {
    DeviceChangeKind::Connected => {
      info!(
          device_id = event.device.id,
          port_path = %event.device.port_path,
          vendor_id = %event.device.vendor_id,
          product_id = %event.device.product_id,
          product_name = event.device.product_name(),
          serial = event.device.serial(),
          is_hub = event.device.is_hub,
          action,
          reason,
          rule,
          "USB device connected"
      );
    },
    DeviceChangeKind::Removed => {
      info!(
          device_id = event.device.id,
          port_path = %event.device.port_path,
          vendor_id = %event.device.vendor_id,
          product_id = %event.device.product_id,
          product_name = event.device.product_name(),
          serial = event.device.serial(),
          is_hub = event.device.is_hub,
          last_action = action,
          reason,
          rule,
          "USB device removed"
      );
    },
    DeviceChangeKind::DecisionChanged => {
      info!(
          device_id = event.device.id,
          port_path = %event.device.port_path,
          vendor_id = %event.device.vendor_id,
          product_id = %event.device.product_id,
          product_name = event.device.product_name(),
          serial = event.device.serial(),
          is_hub = event.device.is_hub,
          previous_action,
          action,
          reason,
          rule,
          "USB authorization decision changed"
      );
    },
  }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum ExplicitDecisionSource {
  PolicyRule,
  ManualOverride,
}

impl ExplicitDecisionSource {
  const fn as_str(self) -> &'static str {
    match self {
      Self::PolicyRule => "policy rule",
      Self::ManualOverride => "manual override",
    }
  }
}

pub(super) fn explicit_decision_source(
  reason: Option<&str>,
  rule: Option<&str>,
) -> Option<ExplicitDecisionSource> {
  if rule.is_some() {
    return Some(ExplicitDecisionSource::PolicyRule);
  }

  (reason == Some("manual override"))
    .then_some(ExplicitDecisionSource::ManualOverride)
}

pub(super) fn log_explicit_device_decision(event: &DeviceChangeEvent) {
  if event.kind == DeviceChangeKind::Removed {
    return;
  }

  let Some(source) =
    explicit_decision_source(Some(&event.reason), event.rule.as_deref())
  else {
    return;
  };

  log_explicit_decision(&ExplicitDecisionLog {
    device: &event.device,
    action: event.action,
    source,
    reason: &event.reason,
    rule: optional_str(event.rule.as_deref()),
  });
}

pub(super) fn log_manual_override(device: &UsbDevice, decision: &Decision) {
  let summary = DeviceSummary::from(device);
  log_explicit_decision(&ExplicitDecisionLog {
    device: &summary,
    action: decision.action,
    source: ExplicitDecisionSource::ManualOverride,
    reason: &decision.reason,
    rule: optional_str(decision.rule.as_deref()),
  });
}

pub(super) fn log_override_cleared(
  device: &UsbDevice,
  previous_action: Option<Action>,
  decision: &Decision,
) {
  let previous_action = previous_action.map_or("unknown", Action::as_str);
  let summary = DeviceSummary::from(device);
  let rule = optional_str(decision.rule.as_deref());
  info!(
      device_id = summary.id,
      port_path = %summary.port_path,
      vendor_id = %summary.vendor_id,
      product_id = %summary.product_id,
      product_name = summary.product_name(),
      serial = summary.serial(),
      is_hub = summary.is_hub,
      previous_action,
      action = decision.action.as_str(),
      reason = %decision.reason,
      rule,
      "manual USB authorization override cleared; policy reapplied"
  );

  if let Some(source) =
    explicit_decision_source(Some(&decision.reason), decision.rule.as_deref())
  {
    log_explicit_decision(&ExplicitDecisionLog {
      device: &summary,
      action: decision.action,
      source,
      reason: &decision.reason,
      rule,
    });
  }
}

struct ExplicitDecisionLog<'a> {
  device: &'a DeviceSummary,
  action: Action,
  source: ExplicitDecisionSource,
  reason: &'a str,
  rule: &'a str,
}

fn log_explicit_decision(log: &ExplicitDecisionLog<'_>) {
  let source = log.source.as_str();
  match log.action {
    Action::Allow => {
      info!(
          device_id = log.device.id,
          port_path = %log.device.port_path,
          vendor_id = %log.device.vendor_id,
          product_id = %log.device.product_id,
          product_name = log.device.product_name(),
          serial = log.device.serial(),
          is_hub = log.device.is_hub,
          action = log.action.as_str(),
          source,
          reason = log.reason,
          rule = log.rule,
          "USB device explicitly allowed"
      );
    },
    Action::Block => {
      info!(
          device_id = log.device.id,
          port_path = %log.device.port_path,
          vendor_id = %log.device.vendor_id,
          product_id = %log.device.product_id,
          product_name = log.device.product_name(),
          serial = log.device.serial(),
          is_hub = log.device.is_hub,
          action = log.action.as_str(),
          source,
          reason = log.reason,
          rule = log.rule,
          "USB device explicitly blocked"
      );
    },
  }
}

fn optional_str(value: Option<&str>) -> &str {
  value.map_or("", |value| value)
}
